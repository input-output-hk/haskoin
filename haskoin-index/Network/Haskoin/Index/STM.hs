{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE TemplateHaskell       #-}

module Network.Haskoin.Index.STM
       ( MerkleTxs
       , NodeException (..)
       -- , NodeStatus (..)
       , NodeT
       , PeerHost (..)
       , PeerHostScore
       , PeerHostSession (..)
       , PeerConnectionType (..)
       , PeerId (..)
       , PeerSession (..)
       -- , PeerStatus (..)
       , SharedNodeState (..)
       , ShowPeerId (..)
       , atomicallyNodeT
       , catchAny
       , getHostSession
       , getNodeState
       , getPeerSession
       , modifyHostSession
       , modifyPeerSession
       , newPeerSession
       , newHostSession
       , orElseNodeT
       , peerHostString
       , readTVarS
       , removePeerSession
       , runNodeT
       , runSqlNodeT
       , takeTMVarS
       , tryGetPeerSession
       , tryPutTMVarS
       , writeTVarS
       ) where

import           Control.Concurrent               (ThreadId)
import           Control.Concurrent.RLock         (RLock)
import qualified Control.Concurrent.RLock         as Lock (new, with)
import           Control.Concurrent.STM           (STM, TMVar, TVar, atomically,
                                                   isEmptyTMVar, modifyTVar',
                                                   newEmptyTMVarIO, newTVar, newTVarIO,
                                                   orElse, putTMVar, readTMVar, readTVar,
                                                   takeTMVar, tryPutTMVar, tryReadTMVar,
                                                   writeTVar)
import           Control.Concurrent.STM.TBMChan   (TBMChan, closeTBMChan, newTBMChan)
import           Control.DeepSeq                  (NFData (..))
import           Control.Exception.Lifted         (Exception, SomeException, catch,
                                                   fromException, throw)
import           Control.Monad                    ((<=<))
import           Control.Monad.Logger             (MonadLoggerIO, logDebug)
import           Control.Monad.Reader             (ReaderT, ask, asks, runReaderT)
import           Control.Monad.Trans              (MonadIO, lift, liftIO)
import           Control.Monad.Trans.Control      (MonadBaseControl, liftBaseOp_)

import           Data.Aeson.TH                    (deriveJSON)
import qualified Data.Map.Strict                  as M (Map, alter, delete, insert,
                                                        lookup)
import           Data.Maybe                       (isJust)
import           Data.Time.Clock                  (UTCTime)
import           Data.Typeable                    (Typeable)
import           Data.Unique                      (Unique, hashUnique)
import           Data.Word                        (Word32, Word64)
import qualified Database.LevelDB.Base            as L (DB)
import           Database.Persist.Sql             (ConnectionPool, SqlBackend,
                                                   SqlPersistT, runSqlConn, runSqlPool)

import           Network.Haskoin.Block            (Block, BlockHash, Headers)
import           Network.Haskoin.Index.HeaderTree (BlockHeight, NodeBlock, Timestamp)
import           Network.Haskoin.Index.Settings   (Config)
import           Network.Haskoin.Node             (Message, Version)
import           Network.Haskoin.Transaction      (Tx, TxHash)
import           Network.Haskoin.Util             (dropFieldLabel)

{- Type aliases -}
type MerkleTxs = [TxHash]

type NodeT = ReaderT SharedNodeState

data PeerConnectionType
    = Incoming
    | Outgoing
    deriving (Eq, Ord)

-- FIXME: Rename `PeerId` simply to `Peer`?
data PeerId = PeerId
    { peerId      :: !Unique
    , peerChannel :: !PeerConnectionType
    } deriving (Eq, Ord)

type PeerHostScore = Word32

newtype ShowPeerId = ShowPeerId
    { getShowPeerId :: PeerId
    } deriving (Eq)

instance Show ShowPeerId where
    show = show . hashUnique . peerId . getShowPeerId

runSql
    :: (MonadBaseControl IO m)
    => SqlPersistT m a -> Either SqlBackend ConnectionPool -> m a
runSql f (Left conn)  = runSqlConn f conn
runSql f (Right pool) = runSqlPool f pool

getNodeState
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => Config
    -> Either SqlBackend ConnectionPool
    -> L.DB
    -> BlockHash
    -> m SharedNodeState
getNodeState sharedConfig sharedSqlBackend sharedLevelDB best = do
    $(logDebug) "Initializing SharedNodeState"
    liftIO $ do
        sharedPeerMap       <- newTVarIO mempty
        sharedHostMap       <- newTVarIO mempty
        sharedBlockWindow   <- newTVarIO mempty
        sharedNetworkHeight <- newTVarIO 0
        sharedBestHeader    <- newTVarIO best
        sharedHeaders       <- newEmptyTMVarIO
        sharedSyncLock      <- Lock.new
        sharedTickleChan    <- atomically $ newTBMChan 1024
        sharedTxChan        <- atomically $ newTBMChan 1024
        sharedTxGetData     <- newTVarIO mempty
        sharedMempool       <- newTVarIO mempty
        sharedRescan        <- newEmptyTMVarIO
        sharedInitialSync   <- newTVarIO False
        sharedDBLock        <- Lock.new
        return SharedNodeState{..}

runNodeT :: Monad m => NodeT m a -> SharedNodeState -> m a
runNodeT = runReaderT

atomicallyNodeT :: MonadIO m => NodeT STM a -> NodeT m a
atomicallyNodeT action = liftIO . atomically . runReaderT action =<< ask

{- PeerHost Session -}
data PeerHostSession = PeerHostSession
    { peerHostSessionReconnect :: !Int
    } deriving (Show)

instance NFData PeerHostSession where
    rnf PeerHostSession {..} = rnf peerHostSessionReconnect

{- Shared Peer STM Type -}

data BlockWindow = BlockWindow
    { blockWindowPeerId    :: !(Maybe PeerId)
    , blockWindowTimestamp :: !(Maybe UTCTime)
    , blockWindowHeight    :: !BlockHeight
    , blockWindowCount     :: !Int
    , blockWindowComplete  :: !Bool
    , blockWindowNode      :: !NodeBlock
    }

data SharedNodeState = SharedNodeState
    { sharedPeerMap       :: !(TVar (M.Map PeerId (TVar PeerSession)))
      -- ^ Map of all active peers and their sessions
    , sharedHostMap       :: !(TVar (M.Map PeerHost (TVar PeerHostSession)))
      -- ^ The peer that is currently syncing the block headers
    , sharedBlockWindow   :: !(TVar (M.Map BlockHash BlockWindow))
      -- ^ Block download window
    , sharedNetworkHeight :: !(TVar BlockHeight)
      -- ^ The current height of the network
    , sharedBestHeader    :: !(TVar BlockHash)
      -- ^ Block headers sent from a peer
    , sharedHeaders       :: !(TMVar (PeerId, Headers))
      -- ^ Block headers sent from a peer
    , sharedSyncLock      :: !RLock
      -- ^ Lock on the header syncing process
    , sharedTxGetData     :: !(TVar (M.Map TxHash [(PeerId, PeerHost)]))
      -- ^ List of Tx GetData requests
    , sharedTickleChan    :: !(TBMChan (PeerId, PeerHost, BlockHash))
      -- ^ Channel containing all the block tickles received from peers
    , sharedTxChan        :: !(TBMChan (PeerId, PeerHost, Tx))
      -- ^ Transaction channel
    , sharedRescan        :: !(TMVar (Either Timestamp BlockHeight))
      -- ^ Rescan requests from a timestamp or from a block height
    , sharedMempool       :: !(TVar (M.Map TxHash Tx))
      -- ^ Transactions to be added to the next block
    , sharedInitialSync   :: !(TVar Bool)
      -- ^ Did we complete the initial blockchain sync?
    , sharedSqlBackend    :: !(Either SqlBackend ConnectionPool)
      -- ^ SQL backend or connection pool for the header tree
    , sharedLevelDB       :: !L.DB
      -- ^ LevelDB connection
    , sharedDBLock        :: !RLock
      -- ^ LevelDB lock
    , sharedConfig        :: !Config
      -- ^ Index configuration
    }

{- Peer Data -}
type PingNonce = Word64

-- Data stored about a peer
data PeerSession = PeerSession
    { peerSessionConnected :: !Bool
      -- ^ True if the peer is connected (completed the handshake)
    , peerSessionVersion   :: !(Maybe Version)
      -- ^ Contains the version message that we received from the peer
    , peerSessionHeight    :: !BlockHeight
      -- ^ Current known height of the peer
    , peerSessionChan      :: !(TBMChan Message)
      -- ^ Message channel to send messages to the peer
    , peerSessionHost      :: !PeerHost
      -- ^ Host to which this peer is connected
    , peerSessionThreadId  :: !ThreadId
      -- ^ Peer ThreadId
    , peerSessionBlockChan :: !(TBMChan Block)
      -- ^ Peer blocks
    , peerSessionPings     :: !(TVar [PingNonce])
      -- ^ Time at which we requested pings
    }

instance NFData PeerSession where
    rnf PeerSession {..} =
        rnf peerSessionConnected `seq`
        rnf peerSessionVersion `seq`
        rnf peerSessionHeight `seq`
        peerSessionChan `seq`
        rnf peerSessionHost `seq` peerSessionThreadId `seq` ()

{- Lock -}

withDBLock :: MonadBaseControl IO m => NodeT m a -> NodeT m a
withDBLock action = do
    lock <- asks sharedDBLock
    liftBaseOp_ (Lock.with lock) action

{- Peer Hosts -}
data PeerHost = PeerHost
    { peerHost :: !String
    , peerPort :: !Int
    } deriving (Eq, Ord)

$(deriveJSON (dropFieldLabel 4) ''PeerHost)

peerHostString :: PeerHost -> String
peerHostString PeerHost {..} = concat [peerHost, ":", show peerPort]

instance NFData PeerHost where
    rnf PeerHost {..} = rnf peerHost `seq` rnf peerPort

{- Getters / Setters -}
insertBlockWindow :: BlockHash -> BlockWindow -> NodeT STM ()
insertBlockWindow key val = do
    bwMap <- readTVarS sharedBlockWindow
    writeTVarS sharedBlockWindow $ M.insert key val bwMap

updateBlockWindow :: BlockHash -> (BlockWindow -> BlockWindow) -> NodeT STM ()
updateBlockWindow key f = do
    bwMap <- readTVarS sharedBlockWindow
    writeTVarS sharedBlockWindow $ M.alter g key bwMap
  where
    g Nothing   = Nothing
    g (Just bw) = Just $ f bw

tryGetPeerSession :: PeerId -> NodeT STM (Maybe PeerSession)
tryGetPeerSession pid = do
    peerMap <- readTVarS sharedPeerMap
    case M.lookup pid peerMap of
        Just sessTVar -> fmap Just $ lift $ readTVar sessTVar
        _             -> return Nothing

getPeerSession :: PeerId -> NodeT STM PeerSession
getPeerSession pid = do
    sessM <- tryGetPeerSession pid
    case sessM of
        Just sess -> return sess
        _         -> throw $ NodeExceptionInvalidPeer $ ShowPeerId pid

newPeerSession :: PeerId -> PeerSession -> NodeT STM ()
newPeerSession pid sess = do
    peerMapTVar <- asks sharedPeerMap
    peerMap <- lift $ readTVar peerMapTVar
    case M.lookup pid peerMap of
        Just _ -> return ()
        Nothing -> do
            sessTVar <- lift $ newTVar sess
            let newMap = M.insert pid sessTVar peerMap
            lift $ writeTVar peerMapTVar $! newMap

modifyPeerSession :: PeerId -> (PeerSession -> PeerSession) -> NodeT STM ()
modifyPeerSession pid f = do
    peerMap <- readTVarS sharedPeerMap
    case M.lookup pid peerMap of
        Just sessTVar -> lift $ modifyTVar' sessTVar f
        _             -> return ()

removePeerSession :: PeerId -> NodeT STM (Maybe PeerSession)
removePeerSession pid = do
    peerMapTVar <- asks sharedPeerMap
    peerMap <- lift $ readTVar peerMapTVar
    -- Close the peer TBMChan
    sessM <- case M.lookup pid peerMap of
        Just sessTVar -> lift $ do
            sess@PeerSession{..} <- readTVar sessTVar
            closeTBMChan peerSessionChan
            closeTBMChan peerSessionBlockChan
            return $ Just sess
        _ -> return Nothing
    -- Remove the peer from the peerMap
    let newMap = M.delete pid peerMap
    lift $ writeTVar peerMapTVar $! newMap
    return sessM

getHostSession :: PeerHost -> NodeT STM (Maybe PeerHostSession)
getHostSession ph = do
    hostMap <- readTVarS sharedHostMap
    lift $
        case M.lookup ph hostMap of
            Just hostSessionTVar -> Just <$> readTVar hostSessionTVar
            _                    -> return Nothing

modifyHostSession :: PeerHost
                  -> (PeerHostSession -> PeerHostSession)
                  -> NodeT STM ()
modifyHostSession ph f = do
    hostMap <- readTVarS sharedHostMap
    case M.lookup ph hostMap of
        Just hostSessionTVar -> lift $ modifyTVar' hostSessionTVar f
        _ -> newHostSession ph $!
            f PeerHostSession { peerHostSessionReconnect = 1 }

newHostSession :: PeerHost -> PeerHostSession -> NodeT STM ()
newHostSession ph session = do
    hostMapTVar <- asks sharedHostMap
    hostMap <- lift $ readTVar hostMapTVar
    case M.lookup ph hostMap of
        Just _ -> return ()
        Nothing ->
            lift $
            do hostSessionTVar <- newTVar session
               let newHostMap = M.insert ph hostSessionTVar hostMap
               writeTVar hostMapTVar $! newHostMap

{- STM Utilities -}
orElseNodeT :: NodeT STM a -> NodeT STM a -> NodeT STM a
orElseNodeT a b = do
    s <- ask
    lift $ runNodeT a s `orElse` runNodeT b s

runSqlNodeT :: (MonadBaseControl IO m) => SqlPersistT m a -> NodeT m a
runSqlNodeT f = asks sharedSqlBackend >>= lift . runSql f

{- TVar Utilities -}
readTVarS :: (SharedNodeState -> TVar a) -> NodeT STM a
readTVarS = lift . readTVar <=< asks

writeTVarS :: (SharedNodeState -> TVar a) -> a -> NodeT STM ()
writeTVarS f val = lift . flip writeTVar val =<< asks f

{- TMVar Utilities -}
takeTMVarS :: (SharedNodeState -> TMVar a) -> NodeT STM a
takeTMVarS = lift . takeTMVar <=< asks

readTMVarS :: (SharedNodeState -> TMVar a) -> NodeT STM a
readTMVarS = lift . readTMVar <=< asks

tryReadTMVarS :: (SharedNodeState -> TMVar a) -> NodeT STM (Maybe a)
tryReadTMVarS = lift . tryReadTMVar <=< asks

putTMVarS :: (SharedNodeState -> TMVar a) -> a -> NodeT STM ()
putTMVarS f val = lift . flip putTMVar val =<< asks f

tryPutTMVarS :: (SharedNodeState -> TMVar a) -> a -> NodeT STM Bool
tryPutTMVarS f val = lift . flip tryPutTMVar val =<< asks f

swapTMVarS :: (SharedNodeState -> TMVar a) -> a -> NodeT STM ()
swapTMVarS f val = lift . flip putTMVar val =<< asks f

isEmptyTMVarS :: (SharedNodeState -> TMVar a) -> NodeT STM Bool
isEmptyTMVarS f = lift . isEmptyTMVar =<< asks f

data NodeException
    = NodeExceptionBanned
    | NodeExceptionConnected
    | NodeExceptionInvalidPeer !ShowPeerId
    | NodeExceptionPeerNotConnected !ShowPeerId
    | NodeException !String
    deriving (Show, Typeable)

instance Exception NodeException

isNodeException :: SomeException -> Bool
isNodeException se = isJust (fromException se :: Maybe NodeException)

catchAny
    :: MonadBaseControl IO m
    => m a -> (SomeException -> m a) -> m a
catchAny = catch

catchAny_
    :: MonadBaseControl IO m
    => m () -> m ()
catchAny_ = flip catchAny $ \_ -> return ()
