module Network.Haskoin.Index.Server.Handlers where

import           Control.Concurrent.RLock         (state)
import           Control.Concurrent.STM           (STM, isEmptyTMVar, readTVar)
import           Control.Concurrent.STM.TBMChan   (isEmptyTBMChan)
import           Control.Monad                    (mzero)
import           Control.Monad.Catch              (MonadMask)
import           Control.Monad.Logger             (MonadLoggerIO, logInfo)
import           Control.Monad.Reader             (ask)
import           Control.Monad.Trans              (MonadIO, lift, liftIO)
import           Control.Monad.Trans.Control      (MonadBaseControl)
import           Data.Aeson                       (FromJSON, ToJSON, object,
                                                   parseJSON, toJSON,
                                                   withObject, (.:), (.=))
import           Data.Aeson.TH                    (deriveJSON)
import           Data.Aeson.Types                 (Options (..),
                                                   SumEncoding (..),
                                                   defaultOptions,
                                                   defaultTaggedObject)
import qualified Data.ByteString.Char8            as C (unpack)
import           Data.Char                        (toLower)
import           Data.List                        (nub, sortBy)
import qualified Data.Map.Strict                  as M (Map, assocs, keys)
import           Data.Maybe                       (fromMaybe)
import           Data.Text                        (Text, pack)
import           Data.Time.Clock                  (UTCTime)
import           Data.Unique                      (hashUnique)
import           Data.Word                        (Word32)
import           Network.Haskoin.Block
import           Network.Haskoin.Crypto
import           Network.Haskoin.Index.BlockChain
import           Network.Haskoin.Index.HeaderTree
import           Network.Haskoin.Index.Peer
import           Network.Haskoin.Index.STM
import           Network.Haskoin.Node
import           Network.Haskoin.Transaction
import           Network.Haskoin.Util

{- Node Status -}

data PeerStatus = PeerStatus
    -- Regular fields
    { peerStatusPeerId         :: !Int
    , peerStatusHost           :: !PeerHost
    , peerStatusConnected      :: !Bool
    , peerStatusHeight         :: !BlockHeight
    , peerStatusProtocol       :: !(Maybe Word32)
    , peerStatusUserAgent      :: !(Maybe String)
    -- Debug fields
    , peerStatusHaveMessage    :: !Bool
    , peerStatusHaveBlocks     :: !Bool
    , peerStatusPingNonces     :: ![PingNonce]
    , peerStatusReconnectTimer :: !(Maybe Int)
    }

$(deriveJSON (dropFieldLabel 10) ''PeerStatus)

-- Same type as RLock.State but the ThreadId is represented as a String
-- (show threadid)
data LockState = LockState { lockState :: !(Maybe (String, Integer)) }
    deriving (Show)

instance ToJSON LockState where
    toJSON (LockState s) = case s of
        Nothing -> object [ "lock-count" .= (0 :: Integer) ]
        Just (tid, cnt) -> object
            [ "lock-count"  .= cnt
            , "lock-thread" .= tid
            ]

instance FromJSON LockState where
    parseJSON = withObject "LockState" $ \o -> do
        cnt <- o .: "lock-count"
        if cnt == 0
           then return $ LockState Nothing
           else do
               tid <- o .: "lock-thread"
               return $ LockState $ Just (tid, cnt)

data NodeStatus = NodeStatus
    -- Regular fields
    { nodeStatusPeers            :: ![PeerStatus]
    , nodeStatusNetworkHeight    :: !BlockHeight
    , nodeStatusBestHeader       :: !BlockHash
    , nodeStatusBestHeaderHeight :: !BlockHeight
    , nodeStatusBestBlock        :: !BlockHash
    , nodeStatusBestBlockHeight  :: !BlockHeight
    , nodeStatusBlockWindow      :: ![( BlockHash
                                      , Maybe Int -- Peer ID
                                      , Maybe UTCTime
                                      , BlockHeight
                                      , Int -- Block count
                                      , Bool -- Completed
                                      )]
    , nodeStatusHaveHeaders      :: !Bool
    , nodeStatusHaveTickles      :: !Bool
    , nodeStatusHaveTxs          :: !Bool
    , nodeStatusGetData          :: ![TxHash]
    , nodeStatusInitialSync      :: !Bool
    , nodeStatusSyncLock         :: !LockState
    , nodeStatusLevelLock        :: !LockState
    }

$(deriveJSON (dropFieldLabel 10) ''NodeStatus)

{- Request/Response types -}

data IndexRequest
    = GetNodeStatusR
    | GetAddressTxsR ![Address]
    | GetOutpointTxsR ![OutPoint]

$(deriveJSON
    defaultOptions
        { constructorTagModifier = map toLower . init
        , sumEncoding = defaultTaggedObject
            { tagFieldName      = "method"
            , contentsFieldName = "params"
            }
        }
    ''IndexRequest
 )

data IndexError
    = IndexInvalidRequest
    | IndexServerError !String

instance ToJSON IndexError where
    toJSON err = case err of
        IndexInvalidRequest -> object
            [ "code"    .= (-32600 :: Int)
            , "message" .= ("Invalid JSON request" :: String)
            ]
        IndexServerError m -> object
            [ "code"    .= (-32000 :: Int)
            , "message" .= m
            ]

instance FromJSON IndexError where
    parseJSON = withObject "IndexError" $ \o -> do
        code <- o .: "code"
        msg  <- o .: "message"
        case (code :: Int) of
            (-32600) -> return IndexInvalidRequest
            (-32000) -> return $ IndexServerError msg
            _        -> mzero

data IndexResponse
    = ResponseNodeStatus !NodeStatus
    | ResponseTxHashes ![TxHash]
    | ResponseError !IndexError

$(deriveJSON
    defaultOptions
        { constructorTagModifier = map toLower . drop 8
        , sumEncoding = defaultTaggedObject
            { tagFieldName      = "type"
            , contentsFieldName = "data"
            }
        }
    ''IndexResponse
 )

{- Server Handlers -}

getNodeStatusR :: (MonadLoggerIO m, MonadBaseControl IO m)
               => NodeT m IndexResponse
getNodeStatusR = do
    $(logInfo) $ format "GetNodeStatusR"
    status <- nodeStatus
    return $ ResponseNodeStatus status

nodeStatus :: (MonadIO m, MonadBaseControl IO m) => NodeT m NodeStatus
nodeStatus = do
    SharedNodeState{..} <- ask
    bestH <- bestIndexedBlock
    let err = error "Could not find bestIndexedBlock in nodeStatus"
    best <- fmap (fromMaybe err) $ runSqlNodeT $ getBlockByHash bestH
    header <- runSqlNodeT getBestBlock
    syncLock <- liftIO $ state sharedSyncLock
    levelLock <- liftIO $ state sharedDBLock
    let nodeStatusBestBlock        = nodeHash best
        nodeStatusBestBlockHeight  = nodeBlockHeight best
        nodeStatusBestHeader       = nodeHash header
        nodeStatusBestHeaderHeight = nodeBlockHeight header
        f (tid, cnt) = (show tid, cnt)
        nodeStatusSyncLock  = LockState $ f <$> syncLock
        nodeStatusLevelLock = LockState $ f <$> levelLock
    atomicallyNodeT $ do
        nodeStatusPeers <- mapM peerStatus =<< getPeers
        lift $ do
            let g (b, BlockWindow p t h i c _) = (b,hashUnique <$> p,t,h,i,c)
                s (_,a) (_,b) =
                    blockWindowHeight a `compare` blockWindowHeight b
            nodeStatusBlockWindow <-
                (map g . sortBy s . M.assocs) <$> readTVar sharedBlockWindow
            nodeStatusNetworkHeight <- readTVar sharedNetworkHeight
            nodeStatusHaveHeaders <- not <$> isEmptyTMVar sharedHeaders
            nodeStatusHaveTickles <- not <$> isEmptyTBMChan sharedTickleChan
            nodeStatusHaveTxs <- not <$> isEmptyTBMChan sharedTxChan
            nodeStatusGetData <- M.keys <$> readTVar sharedTxGetData
            nodeStatusInitialSync <- readTVar sharedInitialSync
            return NodeStatus{..}

peerStatus :: (PeerId, PeerSession) -> NodeT STM PeerStatus
peerStatus (pid, PeerSession{..}) = do
    hostM <- getHostSession peerSessionHost
    let peerStatusPeerId    = hashUnique pid
        peerStatusHost      = peerSessionHost
        peerStatusConnected = peerSessionConnected
        peerStatusHeight    = peerSessionHeight
        peerStatusProtocol  = version <$> peerSessionVersion
        peerStatusUserAgent =
            C.unpack . getVarString . userAgent <$> peerSessionVersion
        peerStatusReconnectTimer = peerHostSessionReconnect <$> hostM
    lift $ do
        peerStatusHaveBlocks  <- not <$> isEmptyTBMChan peerSessionBlockChan
        peerStatusHaveMessage <- not <$> isEmptyTBMChan peerSessionChan
        peerStatusPingNonces  <- readTVar peerSessionPings
        return PeerStatus{..}

getAddressTxsR :: (MonadLoggerIO m, MonadBaseControl IO m, MonadMask m)
               => [Address] -> NodeT m IndexResponse
getAddressTxsR addrs = do
    $(logInfo) $ format $ unwords
        [ "GetAddressTxsR with", show (length addrs), "addresses" ]
    txids <- (nub . concat) <$> mapM getAddressTxs addrs
    return $ ResponseTxHashes txids

getOutpointTxsR :: (MonadLoggerIO m, MonadBaseControl IO m, MonadMask m)
                => [OutPoint] -> NodeT m IndexResponse
getOutpointTxsR ops = do
    $(logInfo) $ format $ unwords
        [ "GetOutpointTxsR with", show (length ops), "outpoints" ]
    txids <- (nub . concat) <$> mapM getOutpointTxs ops
    return $ ResponseTxHashes txids

{- Helpers -}

format :: String -> Text
format str = pack $ "[ZeroMQ] " ++ str

