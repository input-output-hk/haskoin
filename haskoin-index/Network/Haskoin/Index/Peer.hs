{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}

module Network.Haskoin.Index.Peer
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

import           Control.Concurrent                     (killThread, myThreadId,
                                                         threadDelay)
import           Control.Concurrent.Async.Lifted        (link, race, waitAnyCancel,
                                                         waitCatch, withAsync)
import           Control.Concurrent.STM                 (STM, atomically, modifyTVar',
                                                         newTVarIO, readTVar, retry,
                                                         swapTVar)
import           Control.Concurrent.STM.TBMChan         (TBMChan, closeTBMChan,
                                                         newTBMChan, writeTBMChan)
import           Control.Exception.Lifted               (finally, fromException, throw,
                                                         throwIO)
import           Control.Monad                          (forM_, forever, join, unless,
                                                         when)
import           Control.Monad.Logger                   (MonadLoggerIO, logDebug,
                                                         logError, logInfo, logWarn)
import           Control.Monad.Reader                   (asks)
import           Control.Monad.State                    (StateT, evalStateT, get, put)
import           Control.Monad.Trans                    (MonadIO, lift, liftIO)
import           Control.Monad.Trans.Control            (MonadBaseControl)

import           Data.Bits                              (testBit)
import qualified Data.ByteString                        as BS (ByteString, append, null)
import qualified Data.ByteString.Char8                  as C (pack)
import qualified Data.ByteString.Lazy                   as BL (toStrict)
import           Data.Conduit                           (Conduit, Sink, awaitForever,
                                                         yield, ($$), ($=))
import qualified Data.Conduit.Binary                    as CB (take)
import           Data.Conduit.Network                   (appSink, appSockAddr, appSource,
                                                         clientSettings,
                                                         runGeneralTCPClient)
import           Data.Conduit.TMChan                    (sourceTBMChan)
import           Data.List                              (nub, sort, sortBy)
import qualified Data.Map                               as M (assocs, elems, fromList,
                                                              keys, lookup, unionWith)
import           Data.Maybe                             (fromMaybe, isJust, listToMaybe)
import           Data.Serialize                         (decode, encode)
import           Data.Streaming.Network                 (AppData, HasReadWrite)
import           Data.String.Conversions                (cs)
import           Data.Text                              (Text, pack)
import           Data.Time.Clock                        (diffUTCTime, getCurrentTime)
import           Data.Time.Clock.POSIX                  (getPOSIXTime)
import           Data.Unique                            (hashUnique, newUnique)
import           Data.Word                              (Word32)
import           System.Random                          (randomIO)

import           Network.Haskoin.Block                  (BlockHash (..), MerkleBlock (..),
                                                         blockHashToHex, extractMatches,
                                                         headerHash, merkleRoot)
import           Network.Haskoin.Block.Types            (GetHeaders (..), Headers (..))
import           Network.Haskoin.Constants              (haskoinUserAgent)
import           Network.Haskoin.Index.HeaderTree       (BlockHeight, getBlockByHash,
                                                         getBlocksByHash,
                                                         getHeadersFromBestChain,
                                                         nodeBlockHeight, updateBestChain)
import           Network.Haskoin.Index.HeaderTree.Model (NodeBestChain (..),
                                                         NodeBlock (..))
import qualified Network.Haskoin.Index.STM              as STM
import           Network.Haskoin.Node                   (Inv, Message, Version)
import           Network.Haskoin.Transaction            (TxHash (..), txHash, txHashToHex)
import           Network.Haskoin.Util                   (encodeHex)
import           Network.Socket                         (SockAddr (SockAddrInet))

-- TODO: Move constants elsewhere ?
minProtocolVersion :: Word32
minProtocolVersion = 70001

maxHeadersSize :: Int
maxHeadersSize = 2000

-- Start a peer that will try to reconnect when the connection is closed. The
-- reconnections are performed using an expoential backoff time. This function
-- blocks until the peer cannot reconnect (either the peer is banned or we
-- already have a peer connected to the given peer host).
startPeer :: (MonadLoggerIO m, MonadBaseControl IO m)
          => STM.PeerHost
          -> STM.NodeT m ()
startPeer ph@STM.PeerHost{..} = do
    -- Create a new unique ID for this peer
    pid <- liftIO newUnique
    let peer = STM.PeerId { peerId      = pid
                          , peerChannel = STM.Incoming
                          }
    -- Wait if there is a reconnection timeout
    maybeWaitReconnect peer
    -- Launch the peer
    withAsync (startPeerPid pid ph) $ \a -> do
        resE <- liftIO $ waitCatch a
        cleanupPeer pid
        reconnect <- case resE of
            Left se -> do
                $(logError) $ formatPid pid ph $ unwords
                    [ "Peer thread stopped with exception:", show se ]
                return $ case fromException se of
                    Just STM.NodeExceptionBanned    -> False
                    Just STM.NodeExceptionConnected -> False
                    _                               -> True
            Right _ -> do
                $(logDebug) $ formatPid pid ph "Peer thread stopped"
                return True
        -- Try to reconnect
        when reconnect $ startPeer ph
  where
    cleanupPeer pid = do
        $(logWarn) $ formatPid pid ph "Peer is closing. Running cleanup..."
        STM.atomicallyNodeT $ do
            -- Remove the session and close the channels
            _ <- STM.removePeerSession pid
            -- Update the network height
            updateNetworkHeight
    maybeWaitReconnect pid = do
        reconnect <- STM.atomicallyNodeT $ do
            sessM <- STM.getHostSession ph
            case sessM of
                Just STM.PeerHostSession{..} -> do
                    -- Compute the new reconnection time (max 15 minutes)
                    let reconnect = min 900 $ 2 * STM.peerHostSessionReconnect
                    -- Save the reconnection time
                    STM.modifyHostSession ph $ \s ->
                        s{ STM.peerHostSessionReconnect = reconnect }
                    return reconnect
                _ -> return 0
        when (reconnect > 0) $ do
            $(logInfo) $ formatPid pid ph $ unwords
                [ "Reconnecting peer in", show reconnect ]
            -- Wait for some time before calling a reconnection
            liftIO $ threadDelay $ reconnect * 1000000

-- Start a peer with with the given peer host/peer id and initiate the
-- network protocol handshake. This function will block until the peer
-- connection is closed or an exception is raised.
startPeerPid :: (MonadLoggerIO m, MonadBaseControl IO m)
             => STM.PeerId
             -> STM.PeerHost
             -> STM.NodeT m ()
startPeerPid pid ph@STM.PeerHost{..} = do
    tid   <- liftIO myThreadId
    chan  <- liftIO . atomically $ newTBMChan 1024
    bChan <- liftIO . atomically $ newTBMChan 20
    pings <- liftIO $ newTVarIO []

    connected <- atomicallyNodeT $ do
        -- Check if the peer host is already connected
        connected <- isPeerHostConnected ph
        unless connected $ do
            newPeerSession pid PeerSession
                { peerSessionConnected = False
                , peerSessionVersion   = Nothing
                , peerSessionHeight    = 0
                , peerSessionChan      = chan
                , peerSessionHost      = ph
                , peerSessionThreadId  = tid
                , peerSessionBlockChan = bChan
                , peerSessionPings     = pings
                }
            newHostSession ph PeerHostSession
                { peerHostSessionReconnect = 1
                }
        return connected

    when connected $ do
        $(logWarn) $ formatPid pid ph "This host is already connected"
        liftIO . atomically $ do
            closeTBMChan chan
            closeTBMChan bChan
        liftIO $ throwIO NodeExceptionConnected

    $(logDebug) $ formatPid pid ph "Starting a new client TCP connection"
    -- Start the client TCP connection
    let c  = clientSettings peerPort $ C.pack peerHost
    runGeneralTCPClient c (peerTCPClient chan)
    return ()
  where
    peerTCPClient chan ad
                       -- Conduit for receiving messages from the remote host
     = do
        let recvMsg = appSource ad $$ decodeMessage pid ph
            -- Conduit for sending messages to the remote host
            sendMsg = sourceTBMChan chan $= encodeMessage $$ appSink ad
        withAsync recvMsg $ \a1 -> link a1 >> do
            $(logDebug) $ formatPid pid ph
                "Receiving message thread started..."
            withAsync sendMsg $ \a2 -> link a2 >> do
                $(logDebug) $ formatPid pid ph
                    "Sending message thread started..."
                -- Perform the peer handshake before we continue
                -- Timeout after 2 minutes
                resE <- raceTimeout 120 (disconnectPeer pid ph)
                                        (peerHandshake pid ph chan)
                case resE of
                    Left _ -> $(logError) $ formatPid pid ph
                        "Peer timed out during the connection handshake"
                    _ -> withAsync (peerPing pid ph) $ \a3 -> link a3 >> do
                        $(logDebug) $ formatPid pid ph "Ping thread started"
                        _ <- liftIO $ waitAnyCancel [a1, a2, a3]
                        return ()

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
    -> Sink BS.ByteString (STM.NodeT m) ()
decodeMessage pid ph = do
    -- Message header is always 24 bytes
    headerBytes <- BL.toStrict <$> CB.take 24
    -- If headerBytes is empty, the conduit has disconnected and we need to
    -- exit (not recurse). Otherwise, we go into an infinite loop here.
    unless (BS.null headerBytes) $ do
        -- Introspection required to know the length of the payload
        case decode headerBytes of
            Left err -> $(logError) $ formatPid pid ph $ unwords
                [ "Could not decode message header:", err
                , "Bytes:", cs (encodeHex headerBytes)
                ]
            Right (MessageHeader _ cmd len _) -> do
                $(logDebug) $ formatPid pid ph $ unwords
                    [ "Received message header of type", show cmd ]
                payloadBytes <- BL.toStrict <$> CB.take (fromIntegral len)
                case decode $ headerBytes `BS.append` payloadBytes of
                    Left err -> $(logError) $ formatPid pid ph $
                        unwords [ "Could not decode message payload:", err ]
                    Right msg -> lift $ processMessage pid ph msg
        decodeMessage pid ph

-- Handle a message from a peer
processMessage :: (MonadLoggerIO m, MonadBaseControl IO m)
               => STM.PeerId
               -> STM.PeerHost
               -> Message
               -> STM.NodeT m ()
processMessage pid ph msg = case msg of
    MVersion v -> do
        $(logDebug) $ formatPid pid ph "Processing MVersion message"
        join . atomicallyNodeT $ do
            oldVerM <- peerSessionVersion <$> getPeerSession pid
            case oldVerM of
                Just _ -> do
                    _ <- trySendMessage pid $ MReject $ reject
                        MCVersion RejectDuplicate "Duplicate version message"
                    return $ $(logWarn) $
                        formatPid pid ph "Duplicate version message"
                Nothing -> do
                    modifyPeerSession pid $ \s ->
                        s{ peerSessionVersion = Just v }
                    return $ return ()
        $(logDebug) $ formatPid pid ph "Done processing MVersion message"
    MPing (Ping nonce) -> do
        $(logDebug) $ formatPid pid ph "Processing MPing message"
        -- Just reply to the Ping with a Pong message
        _ <- atomicallyNodeT $ trySendMessage pid $ MPong $ Pong nonce
        return ()
    MPong (Pong nonce) -> do
        $(logDebug) $ formatPid pid ph "Processing MPong message"
        atomicallyNodeT $ do
            PeerSession{..} <- getPeerSession pid
            -- Add the Pong response time
            lift $ modifyTVar' peerSessionPings (++ [nonce])
    MHeaders h -> do
        $(logDebug) $ formatPid pid ph "Processing MHeaders message"
        _ <- atomicallyNodeT $ tryPutTMVarS sharedHeaders (pid, h)
        return ()
    MInv inv -> do
        $(logDebug) $ formatPid pid ph "Processing MInv message"
        processInvMessage pid ph inv
    MGetData (GetData inv) -> do
        $(logDebug) $ formatPid pid ph "Processing MGetData message"
        let txlist = filter ((== InvTx) . invType) inv
            txids  = nub $ map (TxHash . invHash) txlist
        $(logDebug) $ formatPid pid ph $ unlines $
            "Received GetData request for transactions"
            : map (("  " ++) . cs . txHashToHex) txids
        -- Add the txids to the GetData request map
        mapTVar <- asks sharedTxGetData
        liftIO . atomically $ modifyTVar' mapTVar $ \datMap ->
            let newMap = M.fromList $ map (\tid -> (tid, [(pid, ph)])) txids
            in  M.unionWith (\x -> nub . (x ++)) newMap datMap
    MTx tx -> do
        $(logDebug) $ formatPid pid ph "Processing MTx message"
        PeerSession{..} <- atomicallyNodeT $ getPeerSession pid
        txChan <- asks sharedTxChan
        $(logDebug) $ formatPid pid ph $ unwords
            [ "Received inbound tx broadcast", cs $ txHashToHex $ txHash tx ]
        liftIO . atomically $ writeTBMChan txChan (pid, ph, tx)
    MBlock b -> do
        $(logDebug) $ formatPid pid ph "Processing MBlock message"
        atomicallyNodeT $ do
            PeerSession{..} <- getPeerSession pid
            lift $ writeTBMChan peerSessionBlockChan b
    _ -> return () -- Ignore other requests

processInvMessage
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => STM.PeerId
    -> STM.PeerHost
    -> Inv
    -> STM.NodeT m ()
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
    => Conduit Message (STM.NodeT m) BS.ByteString
encodeMessage = awaitForever $ yield . encode

peerPing :: (MonadLoggerIO m, MonadBaseControl IO m)
         => STM.PeerId
         -> STM.PeerHost
         -> STM.NodeT m ()
peerPing pid ph = forever $ do
    nonce <- liftIO randomIO
    $(logDebug) $ formatPid pid ph $ unwords
        [ "Sending Ping with nonce", show nonce ]

    nonceTVar <- atomicallyNodeT $ do
        PeerSession{..} <- getPeerSession pid
        sendMessage pid $ MPing $ Ping nonce
        return peerSessionPings

    $(logDebug) $ formatPid pid ph $ unwords
        [ "Waiting for Ping nonce", show nonce ]
    -- Wait 120 seconds for the pong or time out
    startTime <- liftIO getCurrentTime
    resE <- raceTimeout 120 (warnPing nonce) (waitPong nonce nonceTVar)
    case resE of
        Right _ -> do
            endTime <- liftIO getCurrentTime
            let diff = diffUTCTime endTime startTime
            $(logDebug) $ formatPid pid ph $ unwords
                [ "Got response to ping", show nonce
                , "in", show diff, "seconds"
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
    warnPing nonce = do
        $(logWarn) $ formatPid pid ph $ concat
            [ "Did not receive a timely reply for Ping ", show nonce
            ]

peerHandshake
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => STM.PeerId -> STM.PeerHost -> TBMChan Message -> STM.NodeT m ()
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
    go peerVer $ do
        atomicallyNodeT $ do
            -- Save the peers height and update the network height
            modifyPeerSession pid $ \s ->
                s{ peerSessionHeight   = startHeight peerVer
                , peerSessionConnected = True
                }
            updateNetworkHeight
            -- Reset the reconnection timer (exponential backoff)
            modifyHostSession ph $ \s -> s{ peerHostSessionReconnect = 1 }
            -- ACK the version message
            lift $ writeTBMChan chan MVerAck
        $(logDebug) $ formatPid pid ph "Handshake complete"
  where
    go ver action
        | version ver < minProtocolVersion = do
            $(logError) $ formatPid pid ph $ unwords
                [ "Connected to a peer speaking protocol version"
                , show $ N.version ver
                , "but we require at least"
                , show minProtocolVersion
                ]
            liftIO $ throwIO NodeExceptionBanned
        | otherwise = action
    buildVersion
    -- TODO: Get our correct IP here
     = do
        let add = N.NetworkAddress 1 $ SockAddrInet 0 0
            ua = N.VarString haskoinUserAgent
        time <- floor <$> liftIO getPOSIXTime
        rdmn <- liftIO randomIO -- nonce
        height <- nodeBlockHeight <$> runSqlNodeT getBestBlock
        return Version { version     = 70011
                       , services    = 5
                       , timestamp   = time
                       , addrRecv    = add
                       , addrSend    = add
                       , verNonce    = rdmn
                       , userAgent   = ua
                       , startHeight = height
                       , relay       = False
                       }

-- Wait for the version message of a peer and return it
waitPeerVersion :: STM.PeerId -> STM.NodeT STM Version
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

-- Get a free peer that is at least at the network height
waitFreePeer :: STM.NodeT STM (STM.PeerId, STM.PeerSession)
waitFreePeer = do
    bwMap    <- readTVarS sharedBlockWindow
    allPeers <- getPeersAtNetHeight
    let busyPeers = map blockWindowPeerId $ M.elems bwMap
        freePeer (pid,_) = not $ Just pid `elem` busyPeers
        -- Only take available peers
        peers = filter freePeer allPeers
    case peers of
        (res:_) -> return res
        _       -> lift retry

-- Returns the best height of all the peers
getBestPeerHeight :: STM.NodeT STM BlockHeight
getBestPeerHeight = do
    hs <- map (peerSessionHeight . snd) <$> getConnectedPeers
    return $ case hs of
        [] -> 0
        _  -> maximum hs

-- Set the network height to the best height of all peers.
updateNetworkHeight :: STM.NodeT STM ()
updateNetworkHeight = writeTVarS sharedNetworkHeight =<< getBestPeerHeight

getPeers :: STM.NodeT STM [(STM.PeerId, STM.PeerSession)]
getPeers = do
    peerMap <- STM.readTVarS STM.sharedPeerMap
    lift $ mapM f $ M.assocs peerMap
  where
    f (pid, sess) = (,) pid <$> readTVar sess

getConnectedPeers :: STM.NodeT STM [(STM.PeerId, STM.PeerSession)]
getConnectedPeers = filter (STM.peerSessionConnected . snd) <$> getPeers

-- Returns a peer that is connected, at the network height
getPeersAtNetHeight :: STM.NodeT STM [(STM.PeerId, STM.PeerSession)]
getPeersAtNetHeight = do
    height <- STM.readTVarS STM.sharedNetworkHeight
    getPeersAtHeight (== height)

-- Find the current network height
-- Find the best peer at the given height
getPeersAtHeight
    :: (BlockHeight -> Bool)
    -> STM.NodeT STM [(STM.PeerId, STM.PeerSession)]
getPeersAtHeight cmpHeight =
    filter f <$> getPeers
  where
    f (_, p) =
        peerSessionConnected p &&       -- Only connected peers
        cmpHeight (peerSessionHeight p) -- Only peers at the required height

-- Send a message to a peer only if it is connected. It returns True on
-- success.
trySendMessage :: STM.PeerId -> Message -> STM.NodeT STM Bool
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
sendMessage :: STM.PeerId -> Message -> STM.NodeT STM ()
sendMessage pid msg = do
    STM.PeerSession {..} <- STM.getPeerSession pid
    if peerSessionConnected
        then lift $ writeTBMChan peerSessionChan msg
        else throw $ STM.NodeExceptionPeerNotConnected $ STM.ShowPeerId pid

-- Send a message to all connected peers.
sendMessageAll :: Message -> STM.NodeT STM ()
sendMessageAll msg = do
    peerMap <- STM.readTVarS STM.sharedPeerMap
    forM_ (M.keys peerMap) $ \pid -> trySendMessage pid msg

getNetworkHeight :: STM.NodeT STM BlockHeight
getNetworkHeight = STM.readTVarS STM.sharedNetworkHeight

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
