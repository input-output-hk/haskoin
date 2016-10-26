module Network.Haskoin.Index.Server
( runIndex
, nodeStatus
, broadcastTxs
) where

import           Control.Concurrent.Async.Lifted       (async, mapConcurrently,
                                                        waitAnyCancel)
import           Control.Concurrent.STM                (STM, atomically, retry)
import           Control.Concurrent.STM.TBMChan        (readTBMChan)
import           Control.Exception.Lifted              (ErrorCall (..),
                                                        SomeException (..),
                                                        catches)
import qualified Control.Exception.Lifted              as E (Handler (..))
import           Control.Monad                         (forM, forM_, forever,
                                                        unless, void, when)
import           Control.Monad.Catch                   (MonadMask)
import           Control.Monad.Logger                  (MonadLoggerIO,
                                                        filterLogger, logDebug,
                                                        logError, logInfo,
                                                        runStdoutLoggingT)
import           Control.Monad.Reader                  (asks)
import           Control.Monad.Trans                   (lift, liftIO)
import           Control.Monad.Trans.Control           (MonadBaseControl,
                                                        liftBaseOpDiscard)
import           Control.Monad.Trans.Resource          (runResourceT)
import           Data.Aeson                            (decode, encode)
import           Data.ByteString                       (ByteString)
import qualified Data.ByteString.Lazy                  as BL (fromStrict,
                                                              toStrict)
import           Data.Conduit                          (Source, awaitForever,
                                                        yield, ($$))
import           Data.Conduit.Network                  (appSink, appSource,
                                                        clientSettings,
                                                        runGeneralTCPClient)
import qualified Data.HashMap.Strict                   as H (lookup, (!))
import           Data.List                             (nub)
import           Data.List.NonEmpty                    (NonEmpty ((:|)))
import qualified Data.Map                              as M (delete, keys,
                                                             lookup, null)
import           Data.Maybe                            (fromJust, fromMaybe,
                                                        isJust)
import           Data.String.Conversions               (cs)
import           Data.Text                             (pack)
import qualified Database.LevelDB.Base                 as L (Options (..),
                                                             defaultOptions,
                                                             open)
import           Database.Persist.Sql                  (ConnectionPool,
                                                        runMigration)
import           Network.Haskoin.Constants
import           Network.Haskoin.Index.BlockChain
import           Network.Haskoin.Index.Database
import           Network.Haskoin.Index.HeaderTree
import           Network.Haskoin.Index.Peer
import           Network.Haskoin.Index.Server.Handlers
import           Network.Haskoin.Index.Settings
import           Network.Haskoin.Index.STM
import           Network.Haskoin.Node
import           Network.Haskoin.Transaction
import           System.Posix.Daemon                   (Redirection (ToFile),
                                                        runDetached)
import           System.ZMQ4                           (Context, KeyFormat (..),
                                                        Rep (..), Socket, bind,
                                                        receive, receiveMulti,
                                                        send, sendMulti,
                                                        setCurveSecretKey,
                                                        setCurveServer,
                                                        withContext, withSocket,
                                                        z85Decode)

runIndex :: Config -> IO ()
runIndex cfg = maybeDetach cfg $ run $ do
    $(logDebug) "Initializing the sqlite connection pool"
    pool <- initDatabase cfg
    $(logDebug) "Initializing the HeaderTree"
    best <- runSql (initHeaderTree >> getBestBlock) (Right pool)
    let blockSize       = configLevelDBParams cfg H.! "block-size"
        cacheSize       = configLevelDBParams cfg H.! "cache-size"
        writeBufferSize = configLevelDBParams cfg H.! "writebuffer-size"
        opts = L.defaultOptions { L.createIfMissing = True
                                , L.blockSize       = blockSize
                                , L.cacheSize       = cacheSize
                                , L.writeBufferSize = writeBufferSize
                                }
    $(logInfo) $ pack $ unlines $
        [ "Opening LevelDB address index with parameters:"
        , "  blockSize       : " ++ formatBytes blockSize
        , "  cacheSize       : " ++ formatBytes cacheSize
        , "  writeBufferSize : " ++ formatBytes writeBufferSize
        ]
    db <- L.open "haskoin-index" opts
    $(logDebug) "Initializing the NodeState"
    state <- liftIO $ getNodeState cfg (Right pool) db $ nodeHash best
    $(logDebug) "Initializing the LevelDB Index"
    runNodeT initLevelDB state
    $(logDebug) $ pack $ unwords
        [ "Starting indexer with", show $ length hosts, "hosts" ]
    as <- mapM async
        -- Spin up all the peers
        [ runNodeT (void $ mapConcurrently startPeer hosts) state
        -- Blockchain download and address indexing
        , runNodeT (headerSync >> blockSync (length nodes)) state
        -- Initial head sync
        , runNodeT startTickle state
        -- Import solo transactions as they arrive from peers
        , runNodeT startTxs state
        -- Run the ZMQ API server
        , runNodeT runApi state
        ]
    _ <- waitAnyCancel as
    return ()
  where
    run = runResourceT . runLogging
    runLogging = runStdoutLoggingT . filterLogger logFilter
    logFilter _ level = level >= configLogLevel cfg
    nodes = fromMaybe
        (error $ "BTC nodes for " ++ networkName ++ " not found")
        (pack networkName `H.lookup` configBTCNodes cfg)
    hosts = map (\x -> PeerHost (btcNodeHost x) (btcNodePort x)) nodes

formatBytes :: Int -> String
formatBytes b
    | b < k = show b ++ " Bytes"
    | b < m = show (fromIntegral b/fromIntegral k :: Double) ++ " KBytes"
    | b < g = show (fromIntegral b/fromIntegral m :: Double) ++ " MBytes"
    | b < t = show (fromIntegral b/fromIntegral g :: Double) ++ " GBytes"
    | otherwise = show (fromIntegral b/fromIntegral t :: Double) ++ " TBytes"
  where
    k = 1024
    m = k*1024
    g = m*1024
    t = g*1024

maybeDetach :: Config -> IO () -> IO ()
maybeDetach cfg action =
    if configDetach cfg then runDetached pidFile logFile action else action
  where
    pidFile = Just $ configPidFile cfg
    logFile = ToFile $ configLogFile cfg

initDatabase :: (MonadBaseControl IO m, MonadLoggerIO m)
             => Config -> m ConnectionPool
initDatabase cfg = do
    -- Create a database pool
    let dbCfg = fromMaybe
            (error $ "DB config settings for " ++ networkName ++ " not found")
            (pack networkName `H.lookup` configDatabase cfg)
    pool <- getDatabasePool dbCfg
    -- Initialize wallet database
    runSql (runMigration migrateHeaderTree) (Right pool)
    -- Return the semaphrone and the connection pool
    return pool

startTickle :: (MonadLoggerIO m, MonadBaseControl IO m) => NodeT m ()
startTickle = do
    waitInitialSync
    $(logInfo) "Starting tickle processing"
    processTickles

startTxs :: (MonadLoggerIO m, MonadBaseControl IO m) => NodeT m ()
startTxs = do
    waitInitialSync
    $(logInfo) "Starting tx processing"
    txSource $$ awaitForever (lift . indexTx)

waitInitialSync :: (MonadLoggerIO m, MonadBaseControl IO m) => NodeT m ()
waitInitialSync = atomicallyNodeT $ do
    initSync <- readTVarS sharedInitialSync
    unless initSync $ lift retry

-- Source of all transaction broadcasts
txSource :: (MonadLoggerIO m, MonadBaseControl IO m) => Source (NodeT m) Tx
txSource = do
    chan <- lift $ asks sharedTxChan
    $(logDebug) "Waiting to receive a transaction..."
    resM <- liftIO $ atomically $ readTBMChan chan
    case resM of
        Just (pid, ph, tx) -> do
            $(logInfo) $ formatPid pid ph $ unwords
                [ "Received inbound transaction broadcast"
                , cs $ txHashToHex $ txHash tx
                ]
            yield tx >> txSource
        _ -> $(logError) "Tx channel closed unexpectedly"

handleGetData :: (MonadLoggerIO m, MonadBaseControl IO m)
              => (TxHash -> m (Maybe Tx))
              -> NodeT m ()
handleGetData handler = forever $ do
    $(logDebug) "Waiting for GetData transaction requests..."
    -- Wait for tx GetData requests to be available
    txids <- atomicallyNodeT $ do
        datMap <- readTVarS sharedTxGetData
        if M.null datMap then lift retry else return $ M.keys datMap
    forM (nub txids) $ \tid -> lift (handler tid) >>= \txM -> do
        $(logDebug) $ pack $ unwords
            [ "Processing GetData txid request", cs $ txHashToHex tid ]
        pidsM <- atomicallyNodeT $ do
            datMap <- readTVarS sharedTxGetData
            writeTVarS sharedTxGetData $ M.delete tid datMap
            return $ M.lookup tid datMap
        case (txM, pidsM) of
            -- Send the transaction to the required peers
            (Just tx, Just pids) -> forM_ pids $ \(pid, ph) -> do
                $(logDebug) $ formatPid pid ph $ unwords
                    [ "Sending tx", cs $ txHashToHex tid, "to peer" ]
                atomicallyNodeT $ trySendMessage pid $ MTx tx
            _ -> return ()

broadcastTxs :: (MonadLoggerIO m, MonadBaseControl IO m)
             => [TxHash]
             -> NodeT m ()
broadcastTxs txids = do
    forM_ txids $ \tid -> $(logInfo) $ pack $ unwords
        [ "Transaction INV broadcast:", cs $ txHashToHex tid ]
    -- Broadcast an INV message for new transactions
    let msg = MInv $ Inv $ map (InvVector InvTx . getTxHash) txids
    atomicallyNodeT $ sendMessageAll msg

-- Run the main ZeroMQ loop
-- TODO: Support concurrent requests using DEALER socket when we can do
-- concurrent MySQL requests.
runApi :: ( MonadLoggerIO m
          , MonadBaseControl IO m
          , MonadMask m
          )
       => NodeT m ()
runApi = liftBaseOpDiscard withContext $ \ctx -> do
    liftBaseOpDiscard (withSocket ctx Rep) $ \sock -> do
        setupCrypto ctx sock
        cfg <- asks sharedConfig
        liftIO $ bind sock $ configBind cfg
        forever $ do
            bs  <- liftIO $ receive sock
            res <- case decode $ BL.fromStrict bs of
                Just r  -> catchErrors $ dispatchRequest r
                Nothing -> return $ ResponseError IndexInvalidRequest
            liftIO $ send sock [] $ BL.toStrict $ encode res
  where
    setupCrypto :: (MonadLoggerIO m, MonadBaseControl IO m)
                => Context -> Socket a -> NodeT m ()
    setupCrypto ctx sock = do
        cfg <- asks sharedConfig
        let serverKeyM = configServerKey cfg
            clientKeyPubM = configClientKeyPub cfg
        when (isJust serverKeyM) $ liftIO $ do
            let k = fromJust serverKeyM
            setCurveServer True sock
            setCurveSecretKey TextFormat k sock
        when (isJust clientKeyPubM) $ do
            k <- z85Decode (fromJust clientKeyPubM)
            void $ async $ runZapAuth ctx k
    catchErrors m = catches m
        [ E.Handler $ \(ErrorCall err) -> do
            $(logError) $ pack err
            return $ ResponseError $ IndexServerError err
        , E.Handler $ \(SomeException exc) -> do
            $(logError) $ pack $ show exc
            return $ ResponseError $ IndexServerError $ show exc
        ]

runZapAuth :: ( MonadLoggerIO m
              , MonadBaseControl IO m
              )
           => Context -> ByteString -> m ()
runZapAuth ctx k = do
    $(logDebug) $ "Starting ØMQ authentication thread"
    liftBaseOpDiscard (withSocket ctx Rep) $ \zap -> do
        liftIO $ bind zap "inproc://zeromq.zap.01"
        forever $ do
            buffer <- liftIO $ receiveMulti zap
            let actionE =
                    case buffer of
                      v:q:_:_:_:m:p:_ -> do
                          when (v /= "1.0") $
                              Left (q, "500", "Version number not valid")
                          when (m /= "CURVE") $
                              Left (q, "400", "Mechanism not supported")
                          when (p /= k) $
                              Left (q, "400", "Invalid client public key")
                          return q
                      _ -> Left ("", "500", "Malformed request")
            case actionE of
              Right q -> do
                  $(logInfo) "Authenticated client successfully"
                  liftIO $ sendMulti zap $
                      "1.0" :| [q, "200", "OK", "client", ""]
              Left (q, c, m) -> do
                  $(logError) $ pack $ unwords
                      [ "Failed to authenticate client:" , cs c, cs m ]
                  liftIO $ sendMulti zap $
                      "1.0" :| [q, c, m, "", ""]

dispatchRequest :: ( MonadLoggerIO m
                   , MonadBaseControl IO m
                   , MonadMask m
                   )
                => IndexRequest -> NodeT m IndexResponse
dispatchRequest req = case req of
    GetNodeStatusR -> getNodeStatusR
    GetAddressTxsR addrs -> getAddressTxsR addrs
    GetOutpointTxsR ops -> getOutpointTxsR ops

