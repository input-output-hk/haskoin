{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}

module Network.Haskoin.Wallet.Server
       ( going
       , runSPVServer
       , stopSPVServer
       ) where

import           Control.Concurrent.Async.Lifted       (async, link,
                                                        waitAnyCancel)
import           Control.Concurrent.STM                (atomically, retry)
import           Control.Concurrent.STM.TBMChan        (TBMChan, newTBMChan,
                                                        readTBMChan)
import           Control.Concurrent.STM.TVar           (readTVarIO, writeTVar)
import           Control.DeepSeq                       (NFData (..))
import           Control.Exception.Lifted              (ErrorCall (..),
                                                        SomeException (..),
                                                        catches)
import qualified Control.Exception.Lifted              as E (Handler (..))
import           Control.Monad                         (forM_, forever, unless,
                                                        void,
                                                        when)
import           Control.Monad.Base                    (MonadBase)
import           Control.Monad.Catch                   (MonadThrow)
import           Control.Monad.Logger                  (LoggingT, MonadLogger,
                                                        MonadLoggerIO,
                                                        filterLogger, logDebug,
                                                        logError, logInfo,
                                                        logWarn,
                                                        runStdoutLoggingT)
import           Control.Monad.Reader                  (ask)
import           Control.Monad.Trans                   (lift, liftIO)
import           Control.Monad.Trans.Control           (MonadBaseControl,
                                                        liftBaseOpDiscard)
import           Control.Monad.Trans.Resource          (MonadResource,
                                                        ResourceT, runResourceT)
import           Data.Aeson                            (Value, decode, encode)
import           Data.ByteString                       (ByteString)
import qualified Data.ByteString.Lazy                  as BL (fromStrict,
                                                              toStrict)
import           Data.Conduit                          (ConduitM, await,
                                                        awaitForever, ($$))
import qualified Data.HashMap.Strict                   as H (lookup)
import           Data.List.NonEmpty                    (NonEmpty ((:|)))
import qualified Data.Map.Strict                       as M (Map, assocs, elems,
                                                             empty,
                                                             fromListWith,
                                                             insert, notMember,
                                                             null, unionWith)
import           Data.Maybe                            (fromJust, fromMaybe,
                                                        isJust)
import           Data.Monoid                           ((<>))
import           Data.String.Conversions               (cs)
import           Data.Text                             (pack)
import           Data.Word                             (Word32)
import           Database.Esqueleto                    (from, val, where_,
                                                        (&&.), (<=.), (==.),
                                                        (^.))
import           Database.Persist.Sql                  (ConnectionPool,
                                                        runMigration)
import           Network.Haskoin.Block                 (MerkleBlock (..),
                                                        blockHashToHex,
                                                        headerHash)
import           Network.Haskoin.Constants             (networkName)
import           Network.Haskoin.Node.BlockChain       (areBlocksSynced,
                                                        broadcastTxs,
                                                        handleGetData,
                                                        merkleDownload,
                                                        startSPVNode,
                                                        startServerNode,
                                                        txSource)
import           Network.Haskoin.Node.HeaderTree       (BlockChainAction (..),
                                                        migrateHeaderTree,
                                                        nodeBlockHeight,
                                                        nodeHash)
import           Network.Haskoin.Node.Peer             (sendBloomFilter)
import qualified Network.Haskoin.Node.STM              as STM
import           Network.Haskoin.Transaction           (Tx (..), TxHash,
                                                        txHashToHex, verifyTx)
import           Network.Haskoin.Wallet.Accounts       (getBloomFilter,
                                                        initWallet)
import           Network.Haskoin.Wallet.Database       (getDatabasePool)
import           Network.Haskoin.Wallet.Model          (AccountId,
                                                        EntityField (..),
                                                        migrateWallet,
                                                        walletAddrAccount)
import qualified Network.Haskoin.Wallet.Server.Handler as SH
import           Network.Haskoin.Wallet.Settings       (Config (..),
                                                        SPVMode (..))
import           Network.Haskoin.Wallet.Transaction    (getPendingTxs, getTx,
                                                        importMerkles,
                                                        importNetTx,
                                                        walletBestBlock)
import           Network.Haskoin.Wallet.Types          (JsonTx (..), Notif (..),
                                                        WalletException (..),
                                                        WalletResponse (..),
                                                        WalletRequest (..),
                                                        btcNodeHost,
                                                        btcNodePort, join2,
                                                        splitSelect)
import           System.Posix.Daemon                   (Redirection (ToFile),
                                                        killAndWait,
                                                        runDetached)
import           System.ZMQ4                           (Context, KeyFormat (..),
                                                        Pub (..), Rep (..),
                                                        Socket, bind, receive,
                                                        receiveMulti, restrict,
                                                        send, sendMulti,
                                                        setCurveSecretKey,
                                                        setCurveServer,
                                                        setLinger, withContext,
                                                        withSocket, z85Decode)

data EventSession = EventSession
    { eventBatchSize :: !Int
    , eventNewAddrs  :: !(M.Map AccountId Word32)
    } deriving (Eq, Show, Read)

instance NFData EventSession where
    rnf EventSession {..} = rnf eventBatchSize `seq` rnf (M.elems eventNewAddrs)

runSPVServer :: Config -> IO ()
runSPVServer cfg =
    maybeDetach cfg $
    run $ -- start the server process
    -- Initialize the database
    -- Check the operation mode of the server.
    do pool <- initDatabase cfg
       -- Notification channel
       notif <- liftIO $ atomically $ newTBMChan 1000
       case configMode cfg
            -- In this mode, we do not launch an SPV node. We only accept
            -- client requests through the ZMQ API.
             of
           SPVOffline -> runWalletApp $ SH.HandlerSession cfg pool Nothing notif
           -- In this mode, we launch the client ZMQ API and we sync the
           -- wallet database with an SPV node.
           SPVOnline
           -- Initialize the node state
            -> do
               node <- STM.initNodeState (Right pool)
               -- Spin up the node threads
               let session = SH.HandlerSession cfg pool (Just node) notif
               as <-
                   mapM
                       async
                       -- Start the SPV node
                       [ STM.runNodeT (spv pool) node
                       , STM.runNodeT spvs node
                         -- Merkle block synchronization
                         -- Import solo transactions as they arrive from peers
                       , STM.runNodeT (txSource $$ processTx) node
                         -- Respond to transaction GetData requests
                       , STM.runNodeT
                             (handleGetData $ (`SH.runDBPool` pool) . getTx)
                             node
                         -- Re-broadcast pending transactions
                       , STM.runNodeT (broadcastPendingTxs pool) node
                         -- Run the ZMQ API server
                       , runWalletApp session
                       ]
               mapM_ link as
               _ <- waitAnyCancel as
               return ()
  where
    -- Get our bloom filter
    spv pool = do
        (bloom, elems, _) <- SH.runDBPool getBloomFilter pool
        startSPVNode hosts bloom elems
    spvs = startServerNode $ fromIntegral . configSrvPort $ cfg
    -- Setup logging monads
    run = runResourceT . runLogging
    runLogging = runStdoutLoggingT . filterLogger logFilter
    logFilter _ level = level >= configLogLevel cfg
    -- Bitcoin nodes to connect to
    nodes =
        fromMaybe
            (error $ "BTC nodes for " ++ networkName ++ " not found")
            (pack networkName `H.lookup` configBTCNodes cfg)
    hosts = map (\x -> STM.PeerHost (btcNodeHost x) (btcNodePort x)) nodes

-- Run a thread that will re-broadcast pending transactions
broadcastPendingTxs
    :: (MonadBaseControl IO m, MonadLoggerIO m) =>
    ConnectionPool -> STM.NodeT m t
broadcastPendingTxs pool =
    forever $
    do (hash, _) <- STM.runSqlNodeT walletBestBlock
       -- Wait until we are synced
       STM.atomicallyNodeT $
           do synced <- areBlocksSynced hash
              unless synced $ lift retry
       -- Send an INV for those transactions to all peers
       broadcastTxs =<< SH.runDBPool (getPendingTxs 0) pool
       -- Wait until we are not synced
       STM.atomicallyNodeT $
           do synced <- areBlocksSynced hash
              when synced $ lift retry

processTx
    :: ConduitM Tx o (STM.NodeT (LoggingT (ResourceT IO))) ()
processTx =
    awaitForever $
    \tx ->
         lift $ {-
    (_, newAddrs) <- runDBPool (importNetTx tx (Just notif)) pool
    unless (null newAddrs) $ do
        $(logInfo) $ pack $ unwords
            [ "Generated", show $ length newAddrs
            , "new addresses while importing the tx."
            , "Updating the bloom filter"
            ]
        (bloom, elems, _) <- runDBPool getBloomFilter pool
        atomicallyNodeT $ sendBloomFilter bloom elems -}
         do let tid = txHash tx
            $(logDebug) $
                pack $
                unwords ["Inserting into mempool", cs (txHashToHex tid)]
            -- Insert incoming transaction into the mempool (TODO: verification)
            STM.atomicallyNodeT $ -- TODO: fix style
                do mempool <- STM.readTVarS STM.sharedMempool
                   --let newMempool =
                       --M.insertWith (flip const) (txHash tx) tx mempool
                   -- TODO: what if transaction exists already?
                   let newMempool = M.insert tid tx mempool
                   STM.writeTVarS STM.sharedMempool newMempool

initDatabase
    :: (MonadBaseControl IO m, MonadLoggerIO m)
    => Config -> m ConnectionPool
initDatabase cfg
             -- Create a database pool
 = do
    let dbCfg =
            fromMaybe
                (error $
                 "DB config settings for " ++ networkName ++ " not found")
                (pack networkName `H.lookup` configDatabase cfg)
    pool <- getDatabasePool dbCfg
    -- Initialize wallet database
    flip SH.runDBPool pool $
        do _ <- runMigration migrateWallet
           _ <- runMigration migrateHeaderTree
           initWallet $ configBloomFP cfg
    -- Return the semaphrone and the connection pool
    return pool

-- | Accepts a Transaction into the Node's mempool

acceptTx
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => TxHash -> Tx -> STM.NodeT m STM.SharedNodeState
acceptTx tid tx = do
    STM.SharedNodeState {..} <- ask
    mempool <- liftIO $ readTVarIO sharedMempool
    let newMempool =
            if acceptableTx mempool
                then M.insert tid tx mempool
                else mempool
    liftIO $ atomically $ writeTVar sharedMempool newMempool
    return
        STM.SharedNodeState
        { ..
        }
  where
    acceptableTx mp = M.notMember tid mp && verifyTx tx

-- Some logging of the blocks
logBlockChainAction
    :: MonadLogger m
    => BlockChainAction -> m ()
logBlockChainAction action =
    case action of
        BestChain nodes ->
            $(logInfo) $
            pack $
            unwords
                [ "Best chain height"
                , show $ nodeBlockHeight $ last nodes
                , "("
                , cs $ blockHashToHex $ nodeHash $ last nodes
                , ")"
                ]
        ChainReorg _ o n ->
            $(logInfo) $
            pack $
            unlines $
            ["Chain reorg.", "Orphaned blocks:"] ++
            map (("  " ++) . cs . blockHashToHex . nodeHash) o ++
            ["New blocks:"] ++
            map (("  " ++) . cs . blockHashToHex . nodeHash) n ++
            [ unwords
                  [ "Best merkle chain height"
                  , show $ nodeBlockHeight $ last n
                  ]
            ]
        SideChain n ->
            $(logWarn) $
            pack $
            unlines $
            "Side chain:" :
            map (("  " ++) . cs . blockHashToHex . nodeHash) n
        KnownChain n ->
            $(logWarn) $
            pack $
            unlines $
            "Known chain:" :
            map (("  " ++) . cs . blockHashToHex . nodeHash) n

going :: forall (m :: * -> *) o a a1.
         (Num a, MonadResource m, MonadBaseControl IO m, MonadLogger m) =>
         Maybe haskoin-core-0.4.0:Network.Haskoin.Block.Types.BlockHeader
         -> [a1]
         -> M.Map
              (persistent-2.2.4.1:Database.Persist.Class.PersistEntity.Key
                 Network.Haskoin.Wallet.Model.Account)
              a
         -> ConnectionPool
         -> ConduitM
              (Either (MerkleBlock, a1) Tx)
              o
              m
              (Maybe haskoin-core-0.4.0:Network.Haskoin.Block.Types.BlockHeader,
               [a1],
               M.Map
                 (persistent-2.2.4.1:Database.Persist.Class.PersistEntity.Key
                    Network.Haskoin.Wallet.Model.Account)
                 a)
going lastMerkle txsAcc argMap pool =
    go lastMerkle txsAcc argMap
  where
    groupByAcc addrs =
        let xs = map (\a -> (walletAddrAccount a, 1)) addrs
        in M.fromListWith (+) xs
    go lastMerkleM mTxsAcc aMap =
        await >>=
        \resM ->
             case resM of
                 Just (Right tx) -> do
                     $(logDebug) $
                         pack $
                         unwords
                             [ "Importing merkle tx"
                             , cs $ txHashToHex $ txHash tx
                             ]
                     (_, newAddrs) <-
                         lift $ SH.runDBPool (importNetTx tx Nothing) pool
                     $(logDebug) $
                         pack $
                         unwords
                             [ "Generated"
                             , show $ length newAddrs
                             , "new addresses while importing tx"
                             , cs $ txHashToHex $ txHash tx
                             ]
                     let newMap = M.unionWith (+) aMap $ groupByAcc newAddrs
                     go lastMerkleM mTxsAcc newMap
                 Just (Left (MerkleBlock mHead _ _ _, mTxs)) -> do
                     $(logDebug) $
                         pack $
                         unwords
                             [ "Buffering merkle block"
                             , cs $ blockHashToHex $ headerHash mHead
                             ]
                     go (Just mHead) (mTxs : mTxsAcc) aMap
                 -- Done processing this batch. Reverse mTxsAcc as we have been
                 -- prepending new values to it.
                 _ -> return (lastMerkleM, reverse mTxsAcc, aMap)

merkleSync
    :: (MonadLoggerIO m, MonadBaseControl IO m, MonadThrow m, MonadResource m)
    => ConnectionPool -> Word32 -> TBMChan Notif -> STM.NodeT m ()
merkleSync pool bSize notif
                      -- Get our best block
 = do
    (hash, _) <- SH.runDBPool walletBestBlock pool
    $(logDebug) "Starting merkle batch download"
    -- Wait for a new block or a rescan
    (action, source) <- merkleDownload hash bSize
    $(logDebug) "Received a merkle action and source. Processing the source..."
    -- Read and process the data from the source
    (lastMerkleM, mTxsAcc, aMap) <- source $$ going Nothing [] M.empty pool
    $(logDebug) "Merkle source processed and closed"
    -- Send a new bloom filter to our peers if new addresses were generated
    unless (M.null aMap) $
        do $(logInfo) $
               pack $
               unwords
                   [ "Generated"
                   , show $ sum $ M.elems aMap
                   , "new addresses while importing the merkle block."
                   , "Sending our bloom filter."
                   ]
           (bloom, elems, _) <- SH.runDBPool getBloomFilter pool
           STM.atomicallyNodeT $ sendBloomFilter bloom elems
    -- Check if we should rescan the current merkle batch
    $(logDebug) "Checking if we need to rescan the current batch..."
    rescan <- shouldRescan aMap
    when rescan $ $(logDebug) "We need to rescan the current batch"
    -- Compute the new batch size
    let newBSize
            | rescan = max 1 $ bSize `div` 2
            | otherwise = min 500 $ bSize + max 1 (bSize `div` 20)
    when (newBSize /= bSize) $
        $(logDebug) $
        pack $
        unwords
            ["Changing block batch size from", show bSize, "to", show newBSize]
    -- Did we receive all the merkles that we asked for ?
    let missing =
            (headerHash <$> lastMerkleM) /=
            Just (nodeHash $ last $ actionNodes action)
    when missing $
        $(logWarn) $
        pack $
        unwords ["Merkle block stream closed prematurely", show lastMerkleM]
    -- TODO: We could still salvage a partially received batch
    unless (rescan || missing) $
        do $(logDebug) "Importing merkles into the wallet..."
           -- Confirm the transactions
           SH.runDBPool (importMerkles action mTxsAcc (Just notif)) pool
           $(logDebug) "Done importing merkles into the wallet"
           logBlockChainAction action
    merkleSync pool newBSize notif
  where
    shouldRescan aMap
                 -- Try to find an account whos gap is smaller than the number of new
                 -- addresses generated in that account.
     = do
        res <-
            (`SH.runDBPool` pool) $
            splitSelect (M.assocs aMap) $
            \ks ->
                 from $
                 \a -> do
                     let andCond (ai, cnt) =
                             a ^. AccountId ==. val ai &&. a ^. AccountGap <=.
                             val cnt
                     where_ $ join2 $ map andCond ks
                     return $ a ^. AccountId
        return $ not $ null res

maybeDetach :: Config -> IO () -> IO ()
maybeDetach cfg action =
    if configDetach cfg
        then runDetached pidFile logFile action
        else action
  where
    pidFile = Just $ configPidFile cfg
    logFile = ToFile $ configLogFile cfg

stopSPVServer :: Config -> IO ()
stopSPVServer cfg
              -- TODO: Should we send a message instead of killing the process ?
 = killAndWait $ configPidFile cfg

-- Run the main ZeroMQ loop
-- TODO: Support concurrent requests using DEALER socket when we can do
-- concurrent MySQL requests.
runWalletApp
    :: (MonadLoggerIO m
       ,MonadBaseControl IO m
       ,MonadBase IO m
       ,MonadThrow m
       ,MonadResource m)
    => SH.HandlerSession -> m ()
runWalletApp session = do
    na <-
        async $
        liftBaseOpDiscard withContext $
        \ctx ->
             liftBaseOpDiscard (withSocket ctx Pub) $
             \sock -> do
                 liftIO $ setLinger (restrict (0 :: Int)) sock
                 setupCrypto ctx sock
                 liftIO $ bind sock $ configBindNotif $ SH.handlerConfig session
                 forever $
                     do xM <-
                            liftIO $
                            atomically $ readTBMChan $ SH.handlerNotifChan session
                        forM_ xM $
                            \x ->
                                 let (typ, pay) =
                                         case x of
                                             NotifBlock _ ->
                                                 ("[block]", cs $ encode x)
                                             NotifTx JsonTx {..} ->
                                                 ( "{" <> cs jsonTxAccount <>
                                                   "}"
                                                 , cs $ encode x)
                                 in liftIO $ sendMulti sock $ typ :| [pay]
    link na
    liftBaseOpDiscard withContext $
        \ctx ->
             liftBaseOpDiscard (withSocket ctx Rep) $
             \sock -> do
                 liftIO $ setLinger (restrict (0 :: Int)) sock
                 setupCrypto ctx sock
                 liftIO $ bind sock $ configBind $ SH.handlerConfig session
                 forever $
                     do bs <- liftIO $ receive sock
                        res <-
                            case decode $ BL.fromStrict bs of
                                Just r ->
                                    catchErrors $
                                    SH.runHandler (dispatchRequest r) session
                                Nothing ->
                                    return $
                                    ResponseError "Could not decode request"
                        liftIO $ send sock [] $ BL.toStrict $ encode res
  where
    setupCrypto
        :: (MonadLoggerIO m, MonadBaseControl IO m)
        => Context -> Socket a -> m ()
    setupCrypto ctx sock = do
        when (isJust serverKeyM) $
            liftIO $
            do let k = fromJust $ configServerKey $ SH.handlerConfig session
               setCurveServer True sock
               setCurveSecretKey TextFormat k sock
        when (isJust clientKeyPubM) $
            do k <- z85Decode (fromJust clientKeyPubM)
               void $ async $ runZapAuth ctx k
    cfg = SH.handlerConfig session
    serverKeyM = configServerKey cfg
    clientKeyPubM = configClientKeyPub cfg
    catchErrors m =
        catches
            m
            [ E.Handler $
              \(WalletException err) -> do
                  $(logError) $ pack err
                  return $ ResponseError $ pack err
            , E.Handler $
              \(ErrorCall err) -> do
                  $(logError) $ pack err
                  return $ ResponseError $ pack err
            , E.Handler $
              \(SomeException exc) -> do
                  $(logError) $ pack $ show exc
                  return $ ResponseError $ pack $ show exc
            ]

runZapAuth
    :: (MonadLoggerIO m, MonadBaseControl IO m, MonadBase IO m)
    => Context -> ByteString -> m ()
runZapAuth ctx k = do
    $(logDebug) $ "Starting ØMQ authentication thread"
    liftBaseOpDiscard (withSocket ctx Rep) $
        \zap -> do
            liftIO $ setLinger (restrict (0 :: Int)) zap
            liftIO $ bind zap "inproc://zeromq.zap.01"
            forever $
                do buffer <- liftIO $ receiveMulti zap
                   let actionE =
                           case buffer of
                               v:q:_:_:_:m:p:_ -> do
                                   when (v /= "1.0") $
                                       Left
                                           (q, "500", "Version number not valid")
                                   when (m /= "CURVE") $
                                       Left
                                           (q, "400", "Mechanism not supported")
                                   when (p /= k) $
                                       Left
                                           ( q
                                           , "400"
                                           , "Invalid client public key")
                                   return q
                               _ -> Left ("", "500", "Malformed request")
                   case actionE of
                       Right q -> do
                           $(logInfo) "Authenticated client successfully"
                           liftIO $
                               sendMulti zap $
                               "1.0" :| [q, "200", "OK", "client", ""]
                       Left (q, c, m) -> do
                           $(logError) $
                               pack $
                               unwords
                                   [ "Failed to authenticate client:"
                                   , cs c
                                   , cs m
                                   ]
                           liftIO $ sendMulti zap $ "1.0" :| [q, c, m, "", ""]

<<<<<<< HEAD
dispatchRequest
    :: (MonadLoggerIO m
       ,MonadBaseControl IO m
       ,MonadBase IO m
       ,MonadThrow m
       ,MonadResource m)
    => WalletRequest -> SH.Handler m (WalletResponse Value)
dispatchRequest req =
    fmap ResponseValid $
    case req of
        GetAccountsR p            -> SH.getAccountsR p
        PostAccountsR na          -> SH.postAccountsR na
        PostAccountRenameR n n'   -> SH.postAccountRenameR n n'
        GetAccountR n             -> SH.getAccountR n
        PostAccountKeysR n ks     -> SH.postAccountKeysR n ks
        PostAccountGapR n g       -> SH.postAccountGapR n g
        GetAddressesR n t m o p   -> SH.getAddressesR n t m o p
        GetAddressesUnusedR n t p -> SH.getAddressesUnusedR n t p
        GetAddressR n i t m o     -> SH.getAddressR n i t m o
        PutAddressR n i t l       -> SH.putAddressR n i t l
        PostAddressesR n i t      -> SH.postAddressesR n i t
        GetTxsR n p               -> SH.getTxsR n p
        GetAddrTxsR n i t p       -> SH.getAddrTxsR n i t p
        PostTxsR n k a            -> SH.postTxsR n k a
        GetTxR n h                -> SH.getTxR n h
        GetOfflineTxR n h         -> SH.getOfflineTxR n h
        PostOfflineTxR n k t c    -> SH.postOfflineTxR n k t c
        GetBalanceR n mc o        -> SH.getBalanceR n mc o
        PostNodeR na              -> SH.postNodeR na
        DeleteTxIdR t             -> SH.deleteTxIdR t
        GetSyncR a n b            -> SH.getSyncR a (Right n) b
        GetSyncHeightR a n b      -> SH.getSyncR a (Left n) b
        GetPendingR a p           -> SH.getPendingR a p
        GetDeadR a p              -> SH.getDeadR a p
=======
dispatchRequest :: ( MonadLoggerIO m
                   , MonadBaseControl IO m
                   , MonadBase IO m
                   , MonadThrow m
                   , MonadResource m
                   )
                => WalletRequest -> Handler m (WalletResponse Value)
dispatchRequest req = fmap ResponseValid $ case req of
    GetAccountsR p                   -> getAccountsR p
    PostAccountsR na                 -> postAccountsR na
    PostAccountRenameR n n'          -> postAccountRenameR n n'
    GetAccountR n                    -> getAccountR n
    PostAccountKeysR n ks            -> postAccountKeysR n ks
    PostAccountGapR n g              -> postAccountGapR n g
    GetAddressesR n t m o p          -> getAddressesR n t m o p
    GetAddressesUnusedR n t p        -> getAddressesUnusedR n t p
    GetAddressR n i t m o            -> getAddressR n i t m o
    PutAddressR n i t l              -> putAddressR n i t l
    PostAddressesR n i t             -> postAddressesR n i t
    GetTxsR n p                      -> getTxsR n p
    GetAddrTxsR n i t p              -> getAddrTxsR n i t p
    PostTxsR n k a                   -> postTxsR n k a
    GetTxR n h                       -> getTxR n h
    GetOfflineTxR n h                -> getOfflineTxR n h
    PostOfflineTxR n k t c           -> postOfflineTxR n k t c
    GetBalanceR n mc o               -> getBalanceR n mc o
    PostNodeR na                     -> postNodeR na
    DeleteTxIdR t                    -> deleteTxIdR t
    GetSyncR a n b                   -> getSyncR a (Right n) b
    GetSyncHeightR a n b             -> getSyncR a (Left n) b
    GetPendingR a p                  -> getPendingR a p
    GetDeadR a p                     -> getDeadR a p

>>>>>>> origin/address-index
