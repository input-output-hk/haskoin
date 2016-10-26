module Network.Haskoin.Index.Client.Commands
( cmdStart
, cmdStop
, cmdStatus
, cmdAddressTxs
, cmdOutpointTxs
, cmdVersion
)
where

import           Control.Concurrent.Async.Lifted       (async, wait)
import           Control.Monad                         (forM_)
import qualified Control.Monad.Reader                  as R (ReaderT, ask, asks)
import           Control.Monad.Trans                   (liftIO)
import           Data.Aeson                            (FromJSON, ToJSON,
                                                        eitherDecode, encode)
import qualified Data.Aeson.Encode.Pretty              as JSON (Config (..),
                                                                defConfig,
                                                                encodePretty')
import           Data.List                             (intercalate)
import           Data.Maybe                            (fromMaybe, maybeToList)
import           Data.String.Conversions               (cs)
import qualified Data.Yaml                             as YAML (encode)
import           Network.Haskoin.Block
import           Network.Haskoin.Constants
import           Network.Haskoin.Index.Server
import           Network.Haskoin.Index.Server.Handlers
import           Network.Haskoin.Index.Settings
import           Network.Haskoin.Index.STM
import           Network.Haskoin.Transaction
import           Network.Haskoin.Crypto
import           System.Posix.Daemon                   (killAndWait)
import           System.ZMQ4                           (KeyFormat (..),
                                                        Req (..), Socket,
                                                        SocketType, connect,
                                                        receive, restrict, send,
                                                        setCurvePublicKey,
                                                        setCurveSecretKey,
                                                        setCurveServerKey,
                                                        setLinger, withContext,
                                                        withSocket)

type Handler = R.ReaderT Config IO

-- hw start [config] [--detach]
cmdStart :: Handler ()
cmdStart = do
    cfg <- R.ask
    liftIO $ runIndex cfg
    liftIO $ putStrLn "Indexer started"

-- hw stop [config]
cmdStop :: Handler ()
cmdStop = R.ask >>= \cfg -> liftIO $ do
    killAndWait $ configPidFile cfg
    putStrLn "Indexer stopped"

cmdStatus :: Handler ()
cmdStatus =
    sendZmq GetNodeStatusR >>= go . parseResponse
  where
    go (ResponseNodeStatus ns) = formatOutput ns (unlines . printNodeStatus)
    go _ = error "Invalid Status response received"

cmdAddressTxs :: String -> Handler ()
cmdAddressTxs addrStr =
    sendZmq (GetAddressTxsR [addr]) >>= go . parseResponse
  where
    addr = fromMaybe (error "Invalid address") $ base58ToAddr $ cs addrStr
    go (ResponseTxHashes txids) = formatOutput txids $
        unlines . map (cs . txHashToHex)
    go _ = error "Invalid TxHash response received"

cmdOutpointTxs :: String -> String -> Handler ()
cmdOutpointTxs hashStr posStr =
    sendZmq (GetOutpointTxsR [OutPoint tid pos]) >>= go . parseResponse
  where
    tid = fromMaybe (error "Invalid txid") $ hexToTxHash $ cs hashStr
    pos = read posStr
    go (ResponseTxHashes txids) = formatOutput txids $
        unlines . map (cs . txHashToHex)
    go _ = error "Invalid TxHash response received"

cmdVersion :: Handler ()
cmdVersion = liftIO $ do
    putStrLn $ unwords [ "network   :", cs networkName ]
    putStrLn $ unwords [ "user-agent:", cs haskoinUserAgent ]

{- Helpers -}

parseResponse :: Either String IndexResponse -> IndexResponse
parseResponse resE = case resE of
    Right res -> case res of
        ResponseError err -> error $ case err of
            IndexInvalidRequest -> "Invalid JSON request"
            IndexServerError m -> unwords [ "Server error:", m ]
        _ -> res
    Left err -> error err

formatOutput :: (ToJSON a, FromJSON a) => a -> (a -> String) -> Handler ()
formatOutput a handle = R.asks configFormat >>= \f -> liftIO $ case f of
    OutputJSON   -> formatStr $ cs $
        JSON.encodePretty' JSON.defConfig{ JSON.confIndent = 2 } a
    OutputYAML   -> formatStr $ cs $ YAML.encode a
    OutputNormal -> formatStr $ handle a

sendZmq :: IndexRequest -> Handler (Either String IndexResponse)
sendZmq req = do
    cfg <- R.ask
    a <- async $ liftIO $ withContext $ \ctx ->
        withSocket ctx Req $ \sock -> do
            setLinger (restrict (0 :: Int)) sock
            setupAuth cfg sock
            connect sock (configBind cfg)
            send sock [] (cs $ encode req)
            eitherDecode . cs <$> receive sock
    wait a

setupAuth :: (SocketType t)
          => Config
          -> Socket t
          -> IO ()
setupAuth cfg sock = do
    let clientKeyM    = configClientKey    cfg
        clientKeyPubM = configClientKeyPub cfg
        serverKeyPubM = configServerKeyPub cfg
    forM_ clientKeyM $ \clientKey -> do
        let serverKeyPub = fromMaybe
              (error "Server public key not provided")
              serverKeyPubM
            clientKeyPub = fromMaybe
              (error "Client public key not provided")
              clientKeyPubM
        setCurveServerKey TextFormat serverKeyPub sock
        setCurvePublicKey TextFormat clientKeyPub sock
        setCurveSecretKey TextFormat clientKey sock

formatStr :: String -> IO ()
formatStr str = forM_ (lines str) putStrLn

printNodeStatus :: NodeStatus -> [String]
printNodeStatus NodeStatus{..} =
    [ "Network Height    : " ++ show nodeStatusNetworkHeight
    , "Best Header       : " ++ cs (blockHashToHex nodeStatusBestHeader)
    , "Best Header Height: " ++ show nodeStatusBestHeaderHeight
    , "Best Block        : " ++ cs (blockHashToHex nodeStatusBestBlock)
    , "Best Block Height : " ++ show nodeStatusBestBlockHeight
    ] ++
    [ "Block Window      : " ] ++
    [ unwords [ "  - Height: " ++ show h ++ ","
              , "Downloaded: " ++ show i ++ ","
              , "Peer: " ++ fromMaybe "unassigned" (show <$> p) ++ ","
              , "Started: " ++ fromMaybe "not started" (show <$> t) ++ ","
              , "Complete: " ++ show c
              , "(" ++ cs (blockHashToHex b) ++ ")"
              ]
    | (b,p,t,h,i,c) <- nodeStatusBlockWindow
    ] ++
    [ "Pending Headers   : " ++ show nodeStatusHaveHeaders
    , "Pending Tickles   : " ++ show nodeStatusHaveTickles
    , "Pending Txs       : " ++ show nodeStatusHaveTxs
    , "Pending GetData   : " ++ show (map txHashToHex nodeStatusGetData)
    , "Initial Sync      : " ++ show nodeStatusInitialSync
    , "HeaderSync Lock   : " ++ show nodeStatusSyncLock
    , "LevelDB Lock      : " ++ show nodeStatusLevelLock
    ] ++
    [ "Peers: " ] ++
    intercalate ["-"] (map printPeerStatus nodeStatusPeers)

printPeerStatus :: PeerStatus -> [String]
printPeerStatus PeerStatus{..} =
    [ "  Peer Id  : " ++ show peerStatusPeerId
    , "  Peer Host: " ++ peerHostString peerStatusHost
    , "  Connected: " ++ if peerStatusConnected then "yes" else "no"
    , "  Height   : " ++ show peerStatusHeight
    ] ++
    [ "  Protocol : " ++ show p | p <- maybeToList peerStatusProtocol
    ] ++
    [ "  UserAgent: " ++ ua | ua <- maybeToList peerStatusUserAgent
    ] ++
    [ "  Blocks   : " ++ show peerStatusHaveBlocks ] ++
    [ "  Messages : " ++ show peerStatusHaveMessage ] ++
    [ "  Nonces   : " ++ show peerStatusPingNonces ] ++
    [ "  Reconnect: " ++ show t | t <- maybeToList peerStatusReconnectTimer ]

