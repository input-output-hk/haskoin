{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}

module Network.Haskoin.Node.Peer
       ( disconnectPeer
       , formatPid
       , getPeers
       , getPeersAtHeight
       , getPeersAtNetHeight
       , misbehaving
       , raceTimeout
       , sendBloomFilter
       , sendMessage
       , sendMessageAll
       , startIncomingPeer
       , startReconnectPeer
       , trySendMessage
       , updateNetworkHeight
       , waitBloomFilter
       ) where

import           Control.Concurrent              (killThread, myThreadId,
                                                  threadDelay)
import           Control.Concurrent.Async.Lifted (link, race, waitAnyCancel,
                                                  waitCatch, withAsync)
import           Control.Concurrent.STM          (STM, atomically, modifyTVar',
                                                  newTVarIO, readTVar, retry,
                                                  swapTVar)
import           Control.Concurrent.STM.TBMChan  (TBMChan, closeTBMChan,
                                                  newTBMChan, writeTBMChan)
import           Control.Exception.Lifted        (finally, fromException, throw,
                                                  throwIO)
import           Control.Monad                   (forM_, forever, join, unless,
                                                  when)
import           Control.Monad.Logger            (MonadLoggerIO, logDebug,
                                                  logError, logInfo, logWarn)
import           Control.Monad.Reader            (asks)
import           Control.Monad.State             (StateT, evalStateT, get, put)
import           Control.Monad.Trans             (MonadIO, lift, liftIO)
import           Control.Monad.Trans.Control     (MonadBaseControl)
import           Data.Bits                       (testBit)
import qualified Data.ByteString                 as BS (ByteString, append,
                                                        null)
import qualified Data.ByteString.Char8           as C (pack)
import qualified Data.ByteString.Lazy            as BL (toStrict)
import           Data.Conduit                    (Conduit, Sink, awaitForever,
                                                  yield, ($$), ($=))
import qualified Data.Conduit.Binary             as CB (take)
import           Data.Conduit.Network            (appSink, appSockAddr,
                                                  appSource, clientSettings,
                                                  runGeneralTCPClient)
import           Data.Conduit.TMChan             (sourceTBMChan)
import           Data.List                       (nub, sort, sortBy)
import qualified Data.Map                        as M (assocs, elems, fromList,
                                                       keys, lookup, unionWith)
import           Data.Maybe                      (fromMaybe, isJust,
                                                  listToMaybe)
import           Data.Serialize                  (decode, encode)
import           Data.Streaming.Network          (AppData, HasReadWrite)
import           Data.String.Conversions         (cs)
import           Data.Text                       (Text, pack)
import           Data.Time.Clock                 (diffUTCTime, getCurrentTime)
import           Data.Time.Clock.POSIX           (getPOSIXTime)
import           Data.Unique                     (hashUnique, newUnique)
import           Data.Word                       (Word32)
import           Network.Haskoin.Block           (BlockHash (..),
                                                  MerkleBlock (..),
                                                  blockHashToHex,
                                                  extractMatches, headerHash,
                                                  merkleRoot)
import           Network.Haskoin.Block.Types     (GetHeaders(..), Headers(..))
import           Network.Haskoin.Constants       (haskoinUserAgent)
import qualified Network.Haskoin.Node            as N
import           Network.Haskoin.Node.HeaderTree (BlockHeight, nodeBlockHeight,
                                                  getBlockByHash, getBlocksByHash,
                                                  updateBestChain,
                                                  getHeadersFromBestChain)
import qualified Network.Haskoin.Node.STM        as STM
import           Network.Haskoin.Transaction     (TxHash (..), txHash,
                                                  txHashToHex)
import           Network.Haskoin.Util            (encodeHex)
import           Network.Socket                  (SockAddr (SockAddrInet))
import           System.Random                   (randomIO)

import           Network.Haskoin.Node.HeaderTree.Model (NodeBlock(..),
                                                        NodeBestChain(..))

-- TODO: Move constants elsewhere ?
minProtocolVersion :: Word32
minProtocolVersion = 70001

maxHeadersSize :: Int
maxHeadersSize = 2000

-- Start a reconnecting peer that will idle once the connection is established
-- and the handshake is performed.
startPeer
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => STM.PeerHost -> STM.NodeT m ()
startPeer ph@STM.PeerHost {..}
          -- Create a new unique ID for this peer
 = do
    pid <- liftIO newUnique
    -- Start the peer with the given PID
    let peer = STM.PeerId { peerId      = pid
                          , peerChannel = STM.Outgoing
                          }
    startPeerPid peer ph

startIncomingPeer
    :: (MonadBaseControl IO m, MonadLoggerIO m)
    => AppData -> STM.NodeT m ()
startIncomingPeer ad -- Create a new unique ID for this peer
 = do
    pid <- liftIO newUnique
    -- Start the peer with the given PID
    let peer = STM.PeerId { peerId      = pid
                          , peerChannel = STM.Incoming
                          }
    startIncomingPeerPid peer ph ad
  where
    ph = peerHostFromSockAddr $ appSockAddr ad

-- Start a peer that will try to reconnect when the connection is closed. The
-- reconnections are performed using an expoential backoff time. This function
-- blocks until the peer cannot reconnect (either the peer is banned or we
-- already have a peer connected to the given peer host).
startReconnectPeer
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => STM.PeerHost -> STM.NodeT m ()
startReconnectPeer ph@STM.PeerHost {..} -- Create a new unique ID for this peer
 = do
    pid <- liftIO newUnique
    let peer = STM.PeerId { peerId      = pid
                          , peerChannel = STM.Incoming
                          }
    -- Wait if there is a reconnection timeout
    maybeWaitReconnect peer
    -- Launch the peer
    withAsync (startPeerPid peer ph) $
        \a -> do
            resE <- liftIO $ waitCatch a
            reconnect <-
                case resE of
                    Left se -> do
                        $(logError) $
                            formatPid peer ph $
                            unwords
                                ["Peer thread stopped with exception:", show se]
                        return $
                            case fromException se of
                                Just STM.NodeExceptionBanned    -> False
                                Just STM.NodeExceptionConnected -> False
                                _                           -> True
                    Right _ -> do
                        $(logDebug) $ formatPid peer ph "Peer thread stopped"
                        return True
            -- Try to reconnect
            when reconnect $ startReconnectPeer ph
  where
    maybeWaitReconnect
        :: (MonadIO m, MonadLoggerIO m)
        => STM.PeerId -> STM.NodeT m ()
    maybeWaitReconnect pid = do
        reconnect <-
            STM.atomicallyNodeT $
            do sessM <- STM.getHostSession ph
               case sessM of
                   Just STM.PeerHostSession {..}
                   -- Compute the new reconnection time (max 15 minutes)
                    -> do
                       let reconnect = min 900 $ 2 * peerHostSessionReconnect
                       -- Save the reconnection time
                       STM.modifyHostSession ph $
                           \s ->
                                s
                                { STM.peerHostSessionReconnect = reconnect
                                }
                       return reconnect
                   _ -> return 0
        when (reconnect > 0) $
            do $(logInfo) $
                   formatPid pid ph $
                   unwords ["Reconnecting peer in", show reconnect, "seconds"]
               -- Wait for some time before calling a reconnection
               liftIO $ threadDelay $ reconnect * 1000000

-- Start a peer with with the given peer host/peer id and initiate the
-- network protocol handshake. This function will block until the peer
-- connection is closed or an exception is raised.
startPeerPid
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => STM.PeerId -> STM.PeerHost -> STM.NodeT m ()
startPeerPid pid ph@STM.PeerHost {..}
                 -- Check if the peer host is banned
 = do
    banned <- STM.atomicallyNodeT $ isPeerHostBanned ph
    when banned $
        do $(logWarn) $ formatPid pid ph "Failed to start banned host"
           liftIO $ throwIO STM.NodeExceptionBanned
    -- Check if the peer host is already connected
    connected <- STM.atomicallyNodeT $ isPeerHostConnected ph
    when connected $
        do $(logWarn) $ formatPid pid ph "This host is already connected"
           liftIO $ throwIO STM.NodeExceptionConnected
    tid <- liftIO myThreadId
    chan <- liftIO . atomically $ newTBMChan 1024
    mChan <- liftIO . atomically $ newTBMChan 1024
    pings <- liftIO $ newTVarIO []
    STM.atomicallyNodeT $
        do STM.newPeerSession
               pid
               STM.PeerSession
               { peerSessionConnected = False
               , peerSessionVersion = Nothing
               , peerSessionHeight = 0
               , peerSessionChan = chan
               , peerSessionHost = ph
               , peerSessionThreadId = tid
               , peerSessionMerkleChan = mChan
               , peerSessionPings = pings
               , peerSessionScore = Nothing
               }
           STM.newHostSession
               ph
               STM.PeerHostSession
               { peerHostSessionScore = 0
               , peerHostSessionReconnect = 1
               , peerHostSessionLog = []
               }
    $(logDebug) $ formatPid pid ph "Starting a new client TCP connection"
    -- Start the client TCP connection
    let c = clientSettings peerPort $ C.pack peerHost
    runGeneralTCPClient c (peerTCPClient chan) `finally` cleanupPeer
    return ()
  where
    peerTCPClient chan ad
                       -- Conduit for receiving messages from the remote host
     = do
        let recvMsg = appSource ad $$ decodeMessage pid ph
            -- Conduit for sending messages to the remote host
            sendMsg = sourceTBMChan chan $= encodeMessage $$ appSink ad
        withAsync (evalStateT recvMsg Nothing) $
            \a1 ->
                 link a1 >>
                 do $(logDebug) $
                        formatPid pid ph "Receiving message thread started..."
                    withAsync sendMsg $
                        \a2 ->
                             link a2 >>
                             do $(logDebug) $
                                    formatPid
                                        pid
                                        ph
                                        "Sending message thread started..."
                                -- Perform the peer handshake before we continue
                                -- Timeout after 2 minutes
                                resE <-
                                    raceTimeout
                                        120
                                        (disconnectPeer pid ph)
                                        (peerHandshake pid ph chan)
                                case resE of
                                    Left _ ->
                                        $(logError) $
                                        formatPid
                                            pid
                                            ph
                                            "Peer timed out during the connection handshake"
                                    _
                                    -- Send the bloom filter if we have one
                                     -> do
                                        $(logDebug) $
                                            formatPid
                                                pid
                                                ph
                                                "Sending the bloom filter if we have one"
                                        STM.atomicallyNodeT $
                                            do bloomM <- STM.readTVarS STM.sharedBloomFilter
                                               case bloomM of
                                                   Just (bloom, _) ->
                                                       sendMessage pid $
                                                       N.MFilterLoad $
                                                       N.FilterLoad bloom
                                                   _ -> return ()
                                        withAsync (peerPing pid ph) $
                                            \a3 ->
                                                 link a3 >>
                                                 do $(logDebug) $
                                                        formatPid
                                                            pid
                                                            ph
                                                            "Ping thread started"
                                                    _ <-
                                                        liftIO $
                                                        waitAnyCancel
                                                            [a1, a2, a3]
                                                    return ()
    cleanupPeer = do
        $(logWarn) $ formatPid pid ph "Peer is closing. Running cleanup..."
        STM.atomicallyNodeT $
        -- Remove the header syncing peer if necessary
            do hPidM <- STM.readTVarS STM.sharedHeaderPeer
               when (hPidM == Just pid) $ STM.writeTVarS STM.sharedHeaderPeer Nothing
               -- Remove the merkle syncing peer if necessary
               mPidM <- STM.readTVarS STM.sharedMerklePeer
               when (mPidM == Just pid) $ STM.writeTVarS STM.sharedMerklePeer Nothing
               -- Remove the session and close the channels
               sessM <- STM.removePeerSession pid
               case sessM of
                   Just STM.PeerSession {..} ->
                       lift $
                       do closeTBMChan peerSessionChan
                          closeTBMChan peerSessionMerkleChan
                   _ -> return ()
               -- Update the network height
               updateNetworkHeight

peerHostFromSockAddr :: SockAddr -> STM.PeerHost
peerHostFromSockAddr (SockAddrInet portNumber hostAddress) =
    STM.PeerHost
    { ..
    }
  where
    peerPort = read $ show portNumber
    peerHost = show hostAddress
peerHostFromSockAddr _ = error "Must provide SockAddrInet"

startIncomingPeerPid
  :: (MonadBaseControl IO m, MonadLoggerIO m, HasReadWrite ad)
  => STM.PeerId -> STM.PeerHost -> ad -> STM.NodeT m ()
startIncomingPeerPid pid ph ad -- Check if the peer host is banned
 = do
    banned <- STM.atomicallyNodeT $ isPeerHostBanned ph
    when banned $
        do $(logWarn) $ formatPid pid ph "Failed to start banned host"
           liftIO $ throwIO STM.NodeExceptionBanned
    -- Check if the peer host is already connected
    connected <- STM.atomicallyNodeT $ isPeerHostConnected ph
    when connected $
        do $(logWarn) $ formatPid pid ph "This host is already connected"
           liftIO $ throwIO STM.NodeExceptionConnected
    tid <- liftIO myThreadId
    chan <- liftIO . atomically $ newTBMChan 1024
    mChan <- liftIO . atomically $ newTBMChan 1024
    pings <- liftIO $ newTVarIO []
    STM.atomicallyNodeT $
        do STM.newPeerSession
               pid
               STM.PeerSession
               { peerSessionConnected = False
               , peerSessionVersion = Nothing
               , peerSessionHeight = 0
               , peerSessionChan = chan
               , peerSessionHost = ph
               , peerSessionThreadId = tid
               , peerSessionMerkleChan = mChan
               , peerSessionPings = pings
               , peerSessionScore = Nothing
               }
           STM.newHostSession
               ph
               STM.PeerHostSession
               { peerHostSessionScore = 0
               , peerHostSessionReconnect = 1
               , peerHostSessionLog = []
               }
    $(logDebug) $ formatPid pid ph "Starting a new incoming client TCP handler"
    peerTCPClient chan `finally` cleanupPeer
    return ()
  where
    peerTCPClient chan
                  -- Conduit for receiving messages from the remote host
     = do
        let recvMsg = appSource ad $$ decodeMessage pid ph
            -- Conduit for sending messages to the remote host
            sendMsg = sourceTBMChan chan $= encodeMessage $$ appSink ad
        withAsync (evalStateT recvMsg Nothing) $
            \a1 ->
                 link a1 >>
                 do $(logDebug) $
                        formatPid pid ph "Receiving message thread started..."
                    withAsync sendMsg $
                        \a2 ->
                             link a2 >>
                             do $(logDebug) $
                                    formatPid
                                        pid
                                        ph
                                        "Sending message thread started..."
                                -- Perform the peer handshake before we continue
                                -- Timeout after 2 minutes
                                resE <-
                                    raceTimeout
                                        120
                                        (disconnectPeer pid ph)
                                        (peerHandshake pid ph chan)
                                case resE of
                                    Left _ ->
                                        $(logError) $
                                        formatPid
                                            pid
                                            ph
                                            "Peer timed out during the connection handshake"
                                    _
                                    -- Send the bloom filter if we have one
                                     -> do
                                        $(logDebug) $
                                            formatPid
                                                pid
                                                ph
                                                "Sending the bloom filter if we have one"
                                        STM.atomicallyNodeT $
                                            do bloomM <- STM.readTVarS STM.sharedBloomFilter
                                               case bloomM of
                                                   Just (bloom, _) ->
                                                       sendMessage pid $
                                                       N.MFilterLoad $
                                                       N.FilterLoad bloom
                                                   _ -> return ()
                                        withAsync (peerPing pid ph) $
                                            \a3 ->
                                                 link a3 >>
                                                 do $(logDebug) $
                                                        formatPid
                                                            pid
                                                            ph
                                                            "Ping thread started"
                                                    _ <-
                                                        liftIO $
                                                        waitAnyCancel
                                                            [a1, a2, a3]
                                                    return ()
    cleanupPeer = do
        $(logWarn) $ formatPid pid ph "Peer is closing. Running cleanup..."
        STM.atomicallyNodeT $
        -- Remove the header syncing peer if necessary
            do hPidM <- STM.readTVarS STM.sharedHeaderPeer
               when (hPidM == Just pid) $ STM.writeTVarS STM.sharedHeaderPeer Nothing
               -- Remove the merkle syncing peer if necessary
               mPidM <- STM.readTVarS STM.sharedMerklePeer
               when (mPidM == Just pid) $ STM.writeTVarS STM.sharedMerklePeer Nothing
               -- Remove the session and close the channels
               sessM <- STM.removePeerSession pid
               case sessM of
                   Just STM.PeerSession {..} ->
                       lift $
                       do closeTBMChan peerSessionChan
                          closeTBMChan peerSessionMerkleChan
                   _ -> return ()
               -- Update the network height
               updateNetworkHeight

-- Return True if the PeerHost is banned
isPeerHostBanned :: STM.PeerHost -> STM.NodeT STM Bool
isPeerHostBanned ph = do
    hostMap <- STM.readTVarS STM.sharedHostMap
    case M.lookup ph hostMap of
        Just sessTVar -> do
            sess <- lift $ readTVar sessTVar
            return $ STM.isHostScoreBanned $ STM.peerHostSessionScore sess
        _ -> return False

-- Returns True if we have a peer connected to that PeerHost already
isPeerHostConnected :: STM.PeerHost -> STM.NodeT STM Bool
isPeerHostConnected ph = do
    peerMap <- STM.readTVarS STM.sharedPeerMap
    sess <- lift $ mapM readTVar $ M.elems peerMap
    return $ ph `elem` map STM.peerSessionHost sess

-- | Decode messages sent from the remote host and send them to the peers main
-- message queue for processing. If we receive invalid messages, this function
-- will also notify the PeerManager about a misbehaving remote host.
decodeMessage
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => STM.PeerId
    -> STM.PeerHost
    -> Sink BS.ByteString (StateT (Maybe (MerkleBlock, STM.MerkleTxs)) (STM.NodeT m)) ()
decodeMessage pid ph
                  -- Message header is always 24 bytes
 = do
    headerBytes <- BL.toStrict <$> CB.take 24
    -- If headerBytes is empty, the conduit has disconnected and we need to
    -- exit (not recurse). Otherwise, we go into an infinite loop here.
    unless (BS.null headerBytes) $
    -- Introspection required to know the length of the payload
        do case decode headerBytes of
               Left err ->
                   lift . lift $
                   misbehaving pid ph STM.moderateDoS $
                   unwords
                       [ "Could not decode message header:"
                       , err
                       , "Bytes:"
                       , cs (encodeHex headerBytes)
                       ]
               Right (N.MessageHeader _ cmd len _) -> do
                   $(logDebug) $
                       formatPid pid ph $
                       unwords ["Received message header of type", show cmd]
                   payloadBytes <- BL.toStrict <$> CB.take (fromIntegral len)
                   case decode $ headerBytes `BS.append` payloadBytes of
                       Left err ->
                           lift . lift $
                           misbehaving pid ph STM.moderateDoS $
                           unwords ["Could not decode message payload:", err]
                       Right msg -> lift $ processMessage pid ph msg
           decodeMessage pid ph

-- Handle a message from a peer
processMessage
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => STM.PeerId
    -> STM.PeerHost
    -> N.Message
    -> StateT (Maybe (MerkleBlock, STM.MerkleTxs)) (STM.NodeT m) ()
processMessage pid ph msg =
    checkMerkleEnd >>
    case msg of
        N.MVersion v ->
            lift $
            do $(logDebug) $ formatPid pid ph "Processing MVersion message"
               join . STM.atomicallyNodeT $
                   do oldVerM <- STM.peerSessionVersion <$> STM.getPeerSession pid
                      case oldVerM of
                          Just _ -> do
                              _ <-
                                  trySendMessage pid $
                                  N.MReject $
                                  N.reject
                                      N.MCVersion
                                      N.RejectDuplicate
                                      "Duplicate version message"
                              return $
                                  misbehaving
                                      pid
                                      ph
                                      STM.minorDoS
                                      "Duplicate version message"
                          Nothing -> do
                              STM.modifyPeerSession pid $
                                  \s ->
                                       s
                                       { STM.peerSessionVersion = Just v
                                       }
                              return $ return ()
               $(logDebug) $ formatPid pid ph "Done processing MVersion message"
        N.MPing (N.Ping nonce) ->
            lift $
            do $(logDebug) $ formatPid pid ph "Processing MPing message"
               -- Just reply to the Ping with a Pong message
               _ <- STM.atomicallyNodeT $ trySendMessage pid $ N.MPong $ N.Pong nonce
               return ()
        N.MPong (N.Pong nonce) ->
            lift $
            do $(logDebug) $ formatPid pid ph "Processing MPong message"
               STM.atomicallyNodeT $
                   do STM.PeerSession {..} <- STM.getPeerSession pid
                      -- Add the Pong response time
                      lift $ modifyTVar' peerSessionPings (++ [nonce])
        N.MGetHeaders (GetHeaders _ loc hashStop) -> lift $ do
            headers <- STM.runSqlNodeT $ do
                stopHeight <- fmap nodeBlockHeight <$> getBlockByHash hashStop
                serveHeaders loc stopHeight
            STM.atomicallyNodeT $ sendMessage pid (N.MHeaders headers)
        N.MHeaders h@(Headers hList) -> lift $ do
            $(logDebug) $ formatPid pid ph "Processing MHeaders message"
            -- Reconstruct the best chain out of headers
            -- NOTE: it is presumed that NodeBlock is synchronized at this point!
            -- TODO: should be implemented incrementally somewhere else in Full node
            -- TODO: (e.g. at the place where we decide current best chain)
            STM.runSqlNodeT $ do
                let hashes = map (headerHash . fst) hList
                dbHeaders <- map blockToChain <$> getBlocksByHash hashes
                decideBestChain dbHeaders

            -- Save headers in shared state
            _ <- STM.atomicallyNodeT $ STM.tryPutTMVarS STM.sharedHeaders (pid, h)
            return ()
        N.MInv inv ->
            lift $
            do $(logDebug) $ formatPid pid ph "Processing MInv message"
               processInvMessage pid ph inv
        N.MGetData (N.GetData inv) -> do
            $(logDebug) $ formatPid pid ph "Processing MGetData message"
            let txlist = filter ((== N.InvTx) . N.invType) inv
                txids = nub $ map (TxHash . N.invHash) txlist
            $(logDebug) $
                formatPid pid ph $
                unlines $
                "Received GetData request for transactions" :
                map (("  " ++) . cs . txHashToHex) txids
            -- Add the txids to the GetData request map
            mapTVar <- asks STM.sharedTxGetData
            liftIO . atomically $
                modifyTVar' mapTVar $
                \datMap ->
                     let newMap =
                             M.fromList $ map (\tid -> (tid, [(pid, ph)])) txids
                     in M.unionWith (\x -> nub . (x ++)) newMap datMap
        N.MTx tx -> do
            $(logDebug) $ formatPid pid ph "Processing MTx message"
            STM.PeerSession {..} <- lift . STM.atomicallyNodeT $ STM.getPeerSession pid
            txChan <- lift $ asks STM.sharedTxChan
            get >>=
                \merkleM ->
                     case merkleM of
                         Just (_, mTxs) ->
                             if txHash tx `elem` mTxs
                                 then do
                                     $(logDebug) $
                                         formatPid pid ph $
                                         unwords
                                             [ "Received merkle tx"
                                             , cs $ txHashToHex $ txHash tx
                                             ]
                                     liftIO . atomically $
                                         writeTBMChan peerSessionMerkleChan $
                                         Right tx
                                 else do
                                     $(logDebug) $
                                         formatPid pid ph $
                                         unwords
                                             [ "Received tx broadcast (ending a merkle block)"
                                             , cs $ txHashToHex $ txHash tx
                                             ]
                                     endMerkle
                                     liftIO . atomically $
                                         writeTBMChan txChan (pid, ph, tx)
                         _ -> do
                             $(logDebug) $
                                 formatPid pid ph $
                                 unwords
                                     [ "Received tx broadcast"
                                     , cs $ txHashToHex $ txHash tx
                                     ]
                             liftIO . atomically $
                                 writeTBMChan txChan (pid, ph, tx)
        N.MMempool ->
            lift $
            do $(logDebug) $ formatPid pid ph "Processing MMempool message"
               STM.atomicallyNodeT $
                   do mempool <- STM.readTVarS STM.sharedMempool
                      let invVectors =
                              map (N.InvVector N.InvTx . getTxHash) (M.keys mempool)
                      sendMessage pid $ N.MInv $ N.Inv invVectors
        N.MMerkleBlock mb@(MerkleBlock mHead ntx hs fs) -> do
            $(logDebug) $ formatPid pid ph "Processing MMerkleBlock message"
            case extractMatches fs hs (fromIntegral ntx) of
                Left err ->
                    lift $
                    misbehaving pid ph STM.severeDoS $
                    unwords ["Received an invalid merkle block:", err]
                Right (decodedRoot, mTxs)
                -- Make sure that the merkle roots match
                 ->
                    if decodedRoot == merkleRoot mHead
                        then do
                            $(logDebug) $
                                formatPid pid ph $
                                unwords
                                    [ "Received valid merkle block"
                                    , cs $ blockHashToHex $ headerHash mHead
                                    ]
                            forM_ mTxs $
                                \h ->
                                     $(logDebug) $
                                     formatPid pid ph $
                                     unwords
                                         [ "Matched merkle tx:"
                                         , cs $ txHashToHex h
                                         ]
                            if null mTxs
                               -- Deliver the merkle block
                                then lift . STM.atomicallyNodeT $
                                     do STM.PeerSession {..} <- STM.getPeerSession pid
                                        lift $
                                            writeTBMChan peerSessionMerkleChan $
                                            Left (mb, [])
                                     -- Buffer the merkle block until we received all txs
                                else put $ Just (mb, mTxs)
                        else lift $
                             misbehaving
                                 pid
                                 ph
                                 STM.severeDoS
                                 "Received a merkle block with an invalid merkle root"
        _ -> return () -- Ignore other requests
  where
    serveHeaders [] stopHeight = getHeadersFromBestChain Nothing stopHeight maxHeadersSize
    serveHeaders (l:ls) stopHeight = getBlockByHash l >>=
        \maybeBlock -> case maybeBlock of
            Nothing            -> serveHeaders ls stopHeight
            Just NodeBlock{..} -> getHeadersFromBestChain
                                      (Just nodeBlockHeight)
                                      stopHeight
                                      maxHeadersSize
    blockToChain NodeBlock{..} = NodeBestChain nodeBlockHash nodeBlockHeight
    decideBestChain =
        -- Dumb implementation without incremental update.
        -- TODO: fix it.
        updateBestChain
    checkMerkleEnd = unless (isTxMsg msg) endMerkle
    endMerkle =
        get >>=
        \merkleM ->
             case merkleM of
                 Just (mb, mTxs) -> do
                     lift . STM.atomicallyNodeT $
                         do STM.PeerSession {..} <- STM.getPeerSession pid
                            lift $
                                writeTBMChan peerSessionMerkleChan $
                                Left (mb, mTxs)
                     put Nothing
                 _ -> return ()
    isTxMsg (N.MTx _) = True
    isTxMsg _       = False

processInvMessage
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => STM.PeerId -> STM.PeerHost -> N.Inv -> STM.NodeT m ()
processInvMessage pid ph (N.Inv vs) =
    case tickleM of
        Just tickle -> do
            $(logDebug) $
                formatPid pid ph $
                unwords ["Received block tickle", cs $ blockHashToHex tickle]
            tickleChan <- asks STM.sharedTickleChan
            liftIO $ atomically $ writeTBMChan tickleChan (pid, ph, tickle)
        _ -> do
            unless (null txlist) $
                do forM_ txlist $
                       \tid ->
                            $(logDebug) $
                            formatPid pid ph $
                            unwords
                                [ "Received transaction INV"
                                , cs (txHashToHex tid)
                                ]
                   -- We simply request the transactions.
                   -- TODO: Should we do something more elaborate here?
                   STM.atomicallyNodeT $
                       sendMessage pid $
                       N.MGetData $ N.GetData $ map (N.InvVector N.InvTx . getTxHash) txlist
            unless (null blocklist) $
                do $(logDebug) $
                       formatPid pid ph $
                       unlines $
                       "Received block INV" :
                       map (("  " ++) . cs . blockHashToHex) blocklist
                   -- We ignore block INVs as we do headers-first sync
                   return ()
  where
    tickleM =
        case blocklist of
            [h] ->
                if null txlist
                    then Just h
                    else Nothing
            _ -> Nothing
    txlist :: [TxHash]
    txlist = map (TxHash . N.invHash) $ filter ((== N.InvTx) . N.invType) vs
    blocklist :: [BlockHash]
    blocklist = map (BlockHash . N.invHash) $ filter ((== N.InvBlock) . N.invType) vs

-- Single blockhash INV is a tickle
-- | Encode message that are being sent to the remote host.
encodeMessage
    :: MonadLoggerIO m
    => Conduit N.Message (STM.NodeT m) BS.ByteString
encodeMessage = awaitForever $ yield . encode

peerPing
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => STM.PeerId -> STM.PeerHost -> STM.NodeT m ()
peerPing pid ph =
    forever $
    do $(logDebug) $
           formatPid
               pid
               ph
               "Waiting until the peer is available for sending pings..."
       STM.atomicallyNodeT $ waitPeerAvailable pid
       nonce <- liftIO randomIO
       nonceTVar <-
           STM.atomicallyNodeT $
           do STM.PeerSession {..} <- STM.getPeerSession pid
              sendMessage pid $ N.MPing $ N.Ping nonce
              return peerSessionPings
       $(logDebug) $
           formatPid pid ph $ unwords ["Waiting for Ping nonce", show nonce]
       -- Wait 120 seconds for the pong or time out
       startTime <- liftIO getCurrentTime
       resE <- raceTimeout 120 (killPeer nonce) (waitPong nonce nonceTVar)
       case resE of
           Right _ -> do
               endTime <- liftIO getCurrentTime
               (diff, score) <-
                   STM.atomicallyNodeT $
                   do STM.PeerSession {..} <- STM.getPeerSession pid
                      -- Compute the ping time and the new score
                      let diff = diffUTCTime endTime startTime
                          score = 0.5 * diff + 0.5 * fromMaybe diff peerSessionScore
                      -- Save the score in the peer session unless the peer is busy
                      STM.modifyPeerSession pid $
                          \s ->
                               s
                               { STM.peerSessionScore = Just score
                               }
                      return (diff, score)
               $(logDebug) $
                   formatPid pid ph $
                   unwords
                       [ "Got response to ping"
                       , show nonce
                       , "with time"
                       , show diff
                       , "and score"
                       , show score
                       ]
           _ -> return ()
       -- Sleep 30 seconds before sending the next ping
       liftIO $ threadDelay $ 30 * 1000000
  where
    waitPong nonce nonceTVar = do
        ns <-
            liftIO . atomically $
            do ns <- swapTVar nonceTVar []
               if null ns
                   then retry
                   else return ns
        unless (nonce `elem` ns) $ waitPong nonce nonceTVar
    killPeer nonce = do
        $(logWarn) $
            formatPid pid ph $
            concat
                [ "Did not receive a timely reply for Ping "
                , show nonce
                , ". Reconnecting the peer."
                ]
        disconnectPeer pid ph

-- Wait for the Pong message of our Ping nonce to arrive
isBloomDisabled :: N.Version -> Bool
isBloomDisabled ver = N.version ver >= 70011 && not (N.services ver `testBit` 2)

peerHandshake
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => STM.PeerId -> STM.PeerHost -> TBMChan N.Message -> STM.NodeT m ()
peerHandshake pid ph chan = do
    ourVer <- buildVersion
    $(logDebug) $ formatPid pid ph "Sending our version message"
    liftIO . atomically $ writeTBMChan chan $ N.MVersion ourVer
    -- Wait for the peer version message to arrive
    $(logDebug) $ formatPid pid ph "Waiting for the peers version message..."
    peerVer <- STM.atomicallyNodeT $ waitPeerVersion pid
    $(logInfo) $
        formatPid pid ph $
        unlines
            [ unwords
                  [ "Connected to peer host"
                  , show $ N.naAddress $ N.addrSend peerVer
                  ]
            , unwords ["  version  :", show $ N.version peerVer]
            , unwords ["  subVer   :", show $ N.userAgent peerVer]
            , unwords ["  services :", show $ N.services peerVer]
            , unwords ["  time     :", show $ N.timestamp peerVer]
            , unwords ["  blocks   :", show $ N.startHeight peerVer]
            ]
    -- Check the protocol version
    go peerVer $
        do STM.atomicallyNodeT $
           -- Save the peers height and update the network height
               do STM.modifyPeerSession pid $
                      \s ->
                           s
                           { STM.peerSessionHeight = N.startHeight peerVer
                           , STM.peerSessionConnected = True
                           }
                  updateNetworkHeight
                  -- Reset the reconnection timer (exponential backoff)
                  STM.modifyHostSession ph $
                      \s ->
                           s
                           { STM.peerHostSessionReconnect = 1
                           }
                  -- ACK the version message
                  lift $ writeTBMChan chan N.MVerAck
           $(logDebug) $ formatPid pid ph "Handshake complete"
  where
    go ver action
        | N.version ver < minProtocolVersion =
            misbehaving pid ph STM.severeDoS $
            unwords
                [ "Connected to a peer speaking protocol version"
                , show $ N.version ver
                , "but we require at least"
                , show minProtocolVersion
                ]
        | isBloomDisabled ver =
            misbehaving pid ph STM.severeDoS "Peer does not support bloom filters"
        | otherwise = action
    buildVersion
    -- TODO: Get our correct IP here
     = do
        let add = N.NetworkAddress 1 $ SockAddrInet 0 0
            ua = N.VarString haskoinUserAgent
        time <- floor <$> liftIO getPOSIXTime
        rdmn <- liftIO randomIO -- nonce
        height <-
            nodeBlockHeight <$> STM.atomicallyNodeT (STM.readTVarS STM.sharedBestHeader)
        return
            N.Version
            { version = 70011
            , services = 5
            , timestamp = time
            , addrRecv = add
            , addrSend = add
            , verNonce = rdmn
            , userAgent = ua
            , startHeight = height
            , relay = False
            }

-- Wait for the version message of a peer and return it
waitPeerVersion :: STM.PeerId -> STM.NodeT STM N.Version
waitPeerVersion pid = do
    STM.PeerSession {..} <- STM.getPeerSession pid
    case peerSessionVersion of
        Just ver -> return ver
        _        -> lift retry

-- Delete the session of a peer and send a kill signal to the peers thread.
-- Unless the peer is banned, the peer will try to reconnect.
disconnectPeer
    :: (MonadLoggerIO m)
    => STM.PeerId -> STM.PeerHost -> STM.NodeT m ()
disconnectPeer pid ph = do
    sessM <- STM.atomicallyNodeT $ STM.tryGetPeerSession pid
    case sessM of
        Just STM.PeerSession {..} -> do
            $(logDebug) $ formatPid pid ph "Killing the peer thread"
            liftIO $ killThread peerSessionThreadId
        _ -> return ()

{- Peer utility functions -}
--- Wait until the given peer is not syncing headers or merkle blocks
waitPeerAvailable :: STM.PeerId -> STM.NodeT STM ()
waitPeerAvailable pid = do
    hPidM <- STM.readTVarS STM.sharedHeaderPeer
    mPidM <- STM.readTVarS STM.sharedMerklePeer
    when (Just pid `elem` [hPidM, mPidM]) $ lift retry

-- Wait for a non-empty bloom filter to be available
waitBloomFilter :: STM.NodeT STM N.BloomFilter
waitBloomFilter =
    maybe (lift retry) (return . fst) =<<
    STM.readTVarS STM.sharedBloomFilter

sendBloomFilter :: N.BloomFilter -> Int -> STM.NodeT STM ()
sendBloomFilter bloom elems =
    unless (N.isBloomEmpty bloom) $
    do oldBloomM <- STM.readTVarS STM.sharedBloomFilter
       let oldElems = maybe 0 snd oldBloomM
       -- Only update the bloom filter if the number of elements is larger
       when (elems > oldElems) $
           do STM.writeTVarS STM.sharedBloomFilter $ Just (bloom, elems)
              sendMessageAll $ N.MFilterLoad $ N.FilterLoad bloom

-- Returns the median height of all the peers
getMedianHeight :: STM.NodeT STM BlockHeight
getMedianHeight = do
    hs <- map (STM.peerSessionHeight . snd) <$> getConnectedPeers
    let (_, ms) = splitAt (length hs `div` 2) $ sort hs
    return $ fromMaybe 0 $ listToMaybe ms

-- Set the network height to the median height of all peers.
updateNetworkHeight :: STM.NodeT STM ()
updateNetworkHeight = STM.writeTVarS STM.sharedNetworkHeight =<< getMedianHeight

getPeers :: STM.NodeT STM [(STM.PeerId, STM.PeerSession)]
getPeers = do
    peerMap <- STM.readTVarS STM.sharedPeerMap
    lift $ mapM f $ M.assocs peerMap
  where
    f (pid, sess) = (,) pid <$> readTVar sess

getConnectedPeers :: STM.NodeT STM [(STM.PeerId, STM.PeerSession)]
getConnectedPeers = filter (STM.peerSessionConnected . snd) <$> getPeers

-- Returns a peer that is connected, at the network height and
-- with the best score.
getPeersAtNetHeight :: STM.NodeT STM [(STM.PeerId, STM.PeerSession)]
getPeersAtNetHeight = do
    height <- STM.readTVarS STM.sharedNetworkHeight
    getPeersAtHeight (== height)

-- Find the current network height
-- Find the best peer at the given height
getPeersAtHeight :: (BlockHeight -> Bool) -> STM.NodeT STM [(STM.PeerId, STM.PeerSession)]
getPeersAtHeight cmpHeight = do
    peers <- filter f <$> getPeers
    -- Choose the peer with the best score
    return $ sortBy s peers
  where
    f (_, p) =
        STM.peerSessionConnected p && -- Only connected peers
        isJust (STM.peerSessionScore p) && -- Only peers with scores
        cmpHeight (STM.peerSessionHeight p) -- Only peers at the required height
    s (_, a) (_, b) = STM.peerSessionScore a `compare` STM.peerSessionScore b

-- Send a message to a peer only if it is connected. It returns True on
-- success.
trySendMessage :: STM.PeerId -> N.Message -> STM.NodeT STM Bool
trySendMessage pid msg = do
    sessM <- STM.tryGetPeerSession pid
    lift $
        case sessM of
            Just STM.PeerSession {..} ->
                if peerSessionConnected
                    then writeTBMChan peerSessionChan msg >> return True
                    else return False -- The peer is not yet connected
            _ -> return False -- The peer does not exist

-- Send a message to a peer only if it is connected. It returns True on
-- success. Throws an exception if the peer does not exist or is not connected.
sendMessage :: STM.PeerId -> N.Message -> STM.NodeT STM ()
sendMessage pid msg = do
    STM.PeerSession {..} <- STM.getPeerSession pid
    if peerSessionConnected
        then lift $ writeTBMChan peerSessionChan msg
        else throw $ STM.NodeExceptionPeerNotConnected $ STM.ShowPeerId pid

-- Send a message to all connected peers.
sendMessageAll :: N.Message -> STM.NodeT STM ()
sendMessageAll msg = do
    peerMap <- STM.readTVarS STM.sharedPeerMap
    forM_ (M.keys peerMap) $ \pid -> trySendMessage pid msg

getNetworkHeight :: STM.NodeT STM BlockHeight
getNetworkHeight = STM.readTVarS STM.sharedNetworkHeight

misbehaving
    :: (MonadLoggerIO m)
    => STM.PeerId
    -> STM.PeerHost
    -> (STM.PeerHostScore -> STM.PeerHostScore)
    -> String
    -> STM.NodeT m ()
misbehaving pid ph f msg = do
    sessM <-
        STM.atomicallyNodeT $
        do STM.modifyHostSession ph $
               \s ->
                    s
                    { STM.peerHostSessionScore = f $! STM.peerHostSessionScore s
                    , STM.peerHostSessionLog = msg : STM.peerHostSessionLog s
                    }
           STM.getHostSession ph
    case sessM of
        Just STM.PeerHostSession {..} -> do
            $(logWarn) $
                formatPid pid ph $
                unlines
                    [ "Misbehaving peer"
                    , unwords ["  Score:", show peerHostSessionScore]
                    , unwords ["  Reason:", msg]
                    ]
            when (STM.isHostScoreBanned peerHostSessionScore) $ disconnectPeer pid ph
        _ -> return ()

{- Run header tree database action -}
-- runHeaderTree :: MonadIO m => ReaderT L.DB IO a -> NodeT m a
-- runHeaderTree action = undefined
{- Utilities -}
raceTimeout
    :: (MonadIO m, MonadBaseControl IO m)
    => Int
       -- ^ Timeout value in seconds
    -> m a
       -- ^ Action to run if the main action times out
    -> m b
       -- ^ Action to run until the time runs out
    -> m (Either a b)
raceTimeout sec cleanup action = do
    resE <- race (liftIO $ threadDelay (sec * 1000000)) action
    case resE of
        Right res -> return $ Right res
        Left _    -> fmap Left cleanup

formatPid :: STM.PeerId -> STM.PeerHost -> String -> Text
formatPid STM.PeerId {..} ph str =
    pack $ concat
          [ "[Peer "
          , show $ hashUnique peerId
          , " | "
          , STM.peerHostString ph
          , "] "
          , str
          ]
