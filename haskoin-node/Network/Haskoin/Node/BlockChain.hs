{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}

module Network.Haskoin.Node.BlockChain
       ( areBlocksSynced
       , broadcastTxs
       , handleGetData
       , merkleDownload
       , nodeStatus
       , rescanTs
       , startServerNode
       , startSPVNode
       , txSource)
       where

import           Control.Concurrent              (threadDelay)
import           Control.Concurrent.Async.Lifted (link, mapConcurrently,
                                                  waitAny, withAsync)
import           Control.Concurrent.STM          (STM, atomically, isEmptyTMVar,
                                                  putTMVar, readTVar, retry,
                                                  takeTMVar, tryReadTMVar,
                                                  tryTakeTMVar)
import           Control.Concurrent.STM.Lock     (locked)
import qualified Control.Concurrent.STM.Lock     as Lock (with)
import           Control.Concurrent.STM.TBMChan  (isEmptyTBMChan, readTBMChan)
import           Control.Exception.Lifted        (throw)
import           Control.Monad                   (forM, forM_, forever, unless,
                                                  void, when)
import           Control.Monad.Logger            (MonadLoggerIO, logDebug,
                                                  logError, logInfo, logWarn)
import           Control.Monad.Reader            (ask, asks)
import           Control.Monad.Trans             (MonadIO, lift, liftIO)
import           Control.Monad.Trans.Control     (MonadBaseControl, liftBaseOp_)
import qualified Data.ByteString.Char8           as C (unpack)
import           Data.Conduit                    (Source, yield)
import           Data.Conduit.Network            (appSockAddr,
                                                  runGeneralTCPServer,
                                                  serverSettings)
import           Data.List                       (nub)
import qualified Data.Map                        as M (delete, keys, lookup,
                                                       null, size)
import           Data.Maybe                      (isJust, listToMaybe)
import qualified Data.Sequence                   as S (length)
import           Data.String.Conversions         (cs)
import           Data.Text                       (pack)
import           Data.Time.Clock.POSIX           (getPOSIXTime)
import           Data.Unique                     (hashUnique)
import           Data.Word                       (Word32)
import           Network.Haskoin.Block           (BlockHash (..),
                                                  GetHeaders (..), Headers (..),
                                                  MerkleBlock (..),
                                                  blockHashToHex,
                                                  blockTimestamp, headerHash)
import           Network.Haskoin.Node            (BloomFilter (..),
                                                  GetData (..), Inv (..),
                                                  InvType (..), InvVector (..),
                                                  Message (..), VarString (..),
                                                  Version (..), Ping (..))
import qualified Network.Haskoin.Node.HeaderTree as H
import qualified Network.Haskoin.Node.Peer       as P
import qualified Network.Haskoin.Node.STM        as STM
import           Network.Haskoin.Transaction     (Tx, TxHash (..), txHash,
                                                  txHashToHex)
import           Network.Socket                  (SockAddr (SockAddrInet))
import           System.Random                   (randomIO)

startSPVNode
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => [STM.PeerHost] -> BloomFilter -> Int -> STM.NodeT m ()
startSPVNode hosts bloom elems = do
    $(logDebug) "Setting our bloom filter in the node"
    STM.atomicallyNodeT $ P.sendBloomFilter bloom elems
    $(logDebug) $
        pack $ unwords ["Starting SPV node with", show $ length hosts, "hosts"]
    withAsync (void $ mapConcurrently P.startReconnectPeer hosts) $
        \a1 -> do
            link a1
            $(logInfo) "Starting the initial header sync"
            -- headerSync
            $(logInfo) "Initial header sync complete"
            $(logDebug) "Starting the tickle processing thread"
            withAsync processTickles $
                \a2 ->
                     link a2 >>
                     do _ <- liftIO $ waitAny [a1, a2]
                        return ()

startServerNode
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => Int -> STM.NodeT m ()
startServerNode port = do
    $(logDebug) $ pack $ unwords ["Starting server node at", show port]
    runGeneralTCPServer (serverSettings port "*") $
        \ad -> do
            $(logInfo) $
                pack $
                unwords
                [ "Incoming connection from "
                , case appSockAddr ad of
                      SockAddrInet clientPort clientHost ->
                          show clientHost ++ ":" ++ show clientPort
                      _ -> "unknown addr family"
                ]
            P.startIncomingPeer ad

-- Source of all transaction broadcasts
txSource
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => Source (STM.NodeT m) Tx
txSource = do
    chan <- lift $ asks STM.sharedTxChan
    $(logDebug) "Waiting to receive a transaction..."
    resM <- liftIO $ atomically $ readTBMChan chan
    case resM of
        Just (pid, ph, tx) -> do
            $(logInfo) $
               P.formatPid pid ph $
                unwords
                    [ "Received transaction broadcast"
                    , cs $ txHashToHex $ txHash tx
                    ]
            yield tx >> txSource
        _ -> $(logError) "Tx channel closed unexpectedly"

handleGetData
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => (TxHash -> m (Maybe Tx)) -> STM.NodeT m ()
handleGetData handler =
    forever $
    do $(logDebug) "Waiting for GetData transaction requests..."
       -- Wait for tx GetData requests to be available
       txids <-
           STM.atomicallyNodeT $
           do datMap <- STM.readTVarS STM.sharedTxGetData
              if M.null datMap
                  then lift retry
                  else return $ M.keys datMap
       mempool <- STM.atomicallyNodeT $ STM.readTVarS STM.sharedMempool
       forM (nub txids) $
           \tid ->
                lookupTid mempool tid >>=
                \txM -> do
                    $(logDebug) $
                        pack $
                        unwords
                            [ "Processing GetData txid request"
                            , cs $ txHashToHex tid
                            ]
                    pidsM <-
                        STM.atomicallyNodeT $
                        do datMap <- STM.readTVarS STM.sharedTxGetData
                           STM.writeTVarS STM.sharedTxGetData $ M.delete tid datMap
                           return $ M.lookup tid datMap
                    case (txM, pidsM)
                         -- Send the transaction to the required peers
                          of
                        (Just tx, Just pids) ->
                            forM_ pids $
                            \(pid, ph) -> do
                                $(logDebug) $
                                    P.formatPid pid ph $
                                    unwords
                                        [ "Sending tx"
                                        , cs $ txHashToHex tid
                                        , "to peer"
                                        ]
                                STM.atomicallyNodeT $ P.trySendMessage pid $ MTx tx
                        _ -> return ()
  where
    lookupTid mempool tid -- TODO: fix style
     = do
        let mempoolTxM = M.lookup tid mempool
        if isJust mempoolTxM
            then return mempoolTxM
            else lift (handler tid)

-- lookup in mempool, call handler if nothing found
broadcastTxs
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => [TxHash] -> STM.NodeT m ()
broadcastTxs txids = do
    forM_ txids $
        \tid ->
             $(logInfo) $
             pack $ unwords ["Transaction INV broadcast:", cs $ txHashToHex tid]
    -- Broadcast an INV message for new transactions
    let msg = MInv $ Inv $ map (InvVector InvTx . getTxHash) txids
    STM.atomicallyNodeT $ P.sendMessageAll msg

syncMempool
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => STM.NodeT m ()
syncMempool = STM.atomicallyNodeT $ P.sendMessageAll MMempool

-- Broadcast a MEMPOOL message (TODO: filter peers?)
rescanTs :: H.Timestamp -> STM.NodeT STM ()
rescanTs ts = do
    rescanTMVar <- asks STM.sharedRescan
    lift $
    -- Make sure the TMVar is empty
        do _ <- tryTakeTMVar rescanTMVar
           putTMVar rescanTMVar $ Left ts

rescanHeight :: H.BlockHeight -> STM.NodeT STM ()
rescanHeight h = do
    rescanTMVar <- asks STM.sharedRescan
    lift $
    -- Make sure the TMVar is empty
        do _ <- tryTakeTMVar rescanTMVar
           putTMVar rescanTMVar $ Right h

-- Wait for the next merkle batch to be available. This function will check for
-- rescans.
merkleDownload
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => BlockHash
    -> Word32
    -> STM.NodeT m (H.BlockChainAction, Source (STM.NodeT m) (Either (MerkleBlock, STM.MerkleTxs) Tx))
merkleDownload walletHash batchSize
                          -- Store the best block received from the wallet for information only.
                          -- This will be displayed in `hw status`
 = do
    merkleSyncedActions walletHash
    walletBlockM <- STM.runSqlNodeT $ H.getBlockByHash walletHash
    walletBlock <-
        case walletBlockM of
            Just walletBlock -> do
                STM.atomicallyNodeT $ STM.writeTVarS STM.sharedBestBlock walletBlock
                return walletBlock
            Nothing -> error "Could not find wallet best block in headers"
    rescanTMVar <- asks STM.sharedRescan
    -- Wait either for a new block to arrive or a rescan to be triggered
    $(logDebug) "Waiting for a new block or a rescan..."
    resE <-
        STM.atomicallyNodeT $
        STM.orElseNodeT
            (fmap Left $ lift $ takeTMVar rescanTMVar)
            (const (Right ()) <$> waitNewBlock walletHash)
    resM <-
        case resE
             -- A rescan was triggered
              of
            Left valE -> do
                $(logInfo) $ pack $ unwords ["Got rescan request", show valE]
                -- Wait until rescan conditions are met
                newValE <- waitRescan rescanTMVar valE
                $(logDebug) $
                    pack $ unwords ["Rescan condition reached:", show newValE]
                case newValE of
                    Left ts -> tryMerkleDwnTimestamp ts batchSize
                    Right _ -> tryMerkleDwnHeight walletBlock batchSize
            -- Continue download from a hash
            Right _ -> tryMerkleDwnBlock walletBlock batchSize
    case resM of
        Just res -> return res
        _ -> do
            $(logWarn) "Invalid merkleDownload result. Retrying ..."
            -- Sleep 10 seconds and retry
            liftIO $ threadDelay $ 10 * 1000000
            merkleDownload walletHash batchSize
  where
    waitRescan rescanTMVar valE = do
        resE <-
            STM.atomicallyNodeT $
            STM.orElseNodeT
                (fmap Left (lift $ takeTMVar rescanTMVar))
                (waitVal valE >> return (Right valE))
        case resE of
            Left newValE -> waitRescan rescanTMVar newValE
            Right res    -> return res
    waitVal valE =
        case valE of
            Left ts -> waitFastCatchup ts
            Right h -> waitHeight h

-- | Perform some actions only when headers have been synced.
merkleSyncedActions
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => BlockHash -- ^ Wallet best block
    -> STM.NodeT m ()
merkleSyncedActions walletHash =
    asks STM.sharedSyncLock >>=
    \lock ->
         liftBaseOp_ (Lock.with lock) $
         -- Check if we are synced
         do (synced, mempool, header) <-
                STM.atomicallyNodeT $
                do header <- STM.readTVarS STM.sharedBestHeader
                   synced <- areBlocksSynced walletHash
                   mempool <- STM.readTVarS STM.sharedMempool
                   return (synced, mempool, header)
            when synced $
                do $(logInfo) $
                       pack $
                       unwords
                           [ "Merkle blocks are in sync with the"
                           , "network at height"
                           , show walletHash
                           ]
                   -- Prune side chains
                   bestBlock <- STM.runSqlNodeT $ H.pruneChain header
                   STM.atomicallyNodeT $
                   -- Update shared best header after pruning
                       do STM.writeTVarS STM.sharedBestHeader bestBlock
                          STM.writeTVarS STM.sharedMerklePeer Nothing
                   -- Do a mempool sync on the first merkle sync
                   when (M.null mempool) $
                       do STM.atomicallyNodeT $ P.sendMessageAll MMempool
                          $(logInfo) "Requesting a mempool sync"

-- Wait for headers to catch up to the given height
waitHeight :: H.BlockHeight -> STM.NodeT STM ()
waitHeight height = do
    node <- STM.readTVarS STM.sharedBestHeader
    -- Check if we passed the timestamp condition
    unless (height < H.nodeBlockHeight node) $ lift retry

-- Wait for headers to catch up to the given timestamp
waitFastCatchup :: H.Timestamp -> STM.NodeT STM ()
waitFastCatchup ts = do
    node <- STM.readTVarS STM.sharedBestHeader
    -- Check if we passed the timestamp condition
    unless (ts < blockTimestamp (H.nodeHeader node)) $ lift retry

-- Wait for a new block to be available for download
waitNewBlock :: BlockHash -> STM.NodeT STM ()
waitNewBlock bh = do
    node <- STM.readTVarS STM.sharedBestHeader
    -- We have more merkle blocks to download
    unless (bh /= H.nodeHash node) $ lift retry

tryMerkleDwnHeight
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => H.NodeBlock
    -> Word32
    -> STM.NodeT m (Maybe (H.BlockChainAction, Source (STM.NodeT m) (Either (MerkleBlock, STM.MerkleTxs) Tx)))
tryMerkleDwnHeight block batchSize = do
    $(logInfo) $
        pack $
        unwords
            [ "Requesting merkle blocks at height"
            , show $ H.nodeBlockHeight block
            , "with batch size"
            , show batchSize
            ]
    -- Request height - 1 as we want to start downloading at height
    nodeM <- STM.runSqlNodeT $ H.getParentBlock block
    case nodeM of
        Just bn -> tryMerkleDwnBlock bn batchSize
        _ -> do
            $(logDebug) $
                pack $
                unwords
                    [ "Can't download merkle blocks."
                    , "Waiting for headers to sync ..."
                    ]
            return Nothing

tryMerkleDwnTimestamp
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => H.Timestamp
    -> Word32
    -> STM.NodeT m (Maybe (H.BlockChainAction, Source (STM.NodeT m) (Either (MerkleBlock, STM.MerkleTxs) Tx)))
tryMerkleDwnTimestamp ts batchSize = do
    $(logInfo) $
        pack $
        unwords
            [ "Requesting merkle blocks after timestamp"
            , show ts
            , "with batch size"
            , show batchSize
            ]
    nodeM <- STM.runSqlNodeT $ H.getBlockAfterTime ts
    case nodeM of
        Just bh -> tryMerkleDwnBlock bh batchSize
        _ -> do
            $(logDebug) $
                pack $
                unwords
                    [ "Can't download merkle blocks."
                    , "Waiting for headers to sync ..."
                    ]
            return Nothing

tryMerkleDwnBlock
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => H.NodeBlock
    -> Word32
    -> STM.NodeT m (Maybe (H.BlockChainAction, Source (STM.NodeT m) (Either (MerkleBlock, STM.MerkleTxs) Tx)))
tryMerkleDwnBlock bh batchSize = do
    $(logDebug) $
        pack $
        unwords
            [ "Requesting merkle download from block"
            , cs $ blockHashToHex (H.nodeHash bh)
            , "and batch size"
            , show batchSize
            ]
    -- Get the list of merkle blocks to download from our headers
    best <- STM.atomicallyNodeT $ STM.readTVarS STM.sharedBestHeader
    action <- STM.runSqlNodeT $ H.getBlockWindow best bh batchSize
    case H.actionNodes action of
        [] -> do
            $(logError) "BlockChainAction was empty"
            return Nothing
        ns
        -- Wait for a peer available for merkle download
         -> do
            (pid, STM.PeerSession {..}) <- waitMerklePeer $ H.nodeBlockHeight $ last ns
            $(logDebug) $
                P.formatPid pid peerSessionHost $
                unwords
                    [ "Found merkle downloading peer with score"
                    , show peerSessionScore
                    ]
            let source = peerMerkleDownload pid peerSessionHost action
            return $ Just (action, source)
  where
    waitMerklePeer height =
        STM.atomicallyNodeT $
        do pidM <- STM.readTVarS STM.sharedHeaderPeer
           allPeers <- P.getPeersAtHeight (>= height)
           let f (pid, _) = Just pid /= pidM
               -- Filter out the peer syncing headers (if there is one)
               peers = filter f allPeers
           case listToMaybe peers of
               Just res@(pid, _) -> do
                   STM.writeTVarS STM.sharedMerklePeer $ Just pid
                   return res
               _ -> lift retry

peerMerkleDownload
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => STM.PeerId
    -> STM.PeerHost
    -> H.BlockChainAction
    -> Source (STM.NodeT m) (Either (MerkleBlock, STM.MerkleTxs) Tx)
peerMerkleDownload pid ph action = do
    let bids = map H.nodeHash $ H.actionNodes action
        vs = map (InvVector InvMerkleBlock . getBlockHash) bids
    $(logInfo) $
        P.formatPid pid ph $
        unwords ["Requesting", show $ length bids, "merkle block(s)"]
    nonce <- liftIO randomIO
    -- Request a merkle batch download
    sessM <-
        lift . STM.atomicallyNodeT $
        do _ <- P.trySendMessage pid $ MGetData $ GetData vs
           -- Send a ping to have a recognizable end message for
           -- the last merkle block download.
           _ <- P.trySendMessage pid $ MPing $ Ping nonce
           STM.tryGetPeerSession pid
    case sessM of
        Just STM.PeerSession {..} -> checkOrder peerSessionMerkleChan bids
        _ -> lift . STM.atomicallyNodeT $ STM.writeTVarS STM.sharedMerklePeer Nothing
  where
    checkOrder _ [] = lift . STM.atomicallyNodeT $ STM.writeTVarS STM.sharedMerklePeer Nothing
    checkOrder chan (bid:bids)
                    -- Read the channel or disconnect the peer after waiting for 2 minutes
     = do
        resM <-
            lift $
            P.raceTimeout
                120
                (P.disconnectPeer pid ph)
                (liftIO . atomically $ readTBMChan chan)
        case resM
             -- Forward transactions
              of
            Right (Just res@(Right _)) ->
                yield res >> checkOrder chan (bid : bids)
            Right (Just res@(Left (MerkleBlock mHead _ _ _, _))) -> do
                let mBid = headerHash mHead
                $(logDebug) $
                    P.formatPid pid ph $
                    unwords
                        ["Processing merkle block", cs $ blockHashToHex mBid]
                -- Check if we were expecting this merkle block
                if mBid == bid
                    then yield res >> checkOrder chan bids
                    else lift $
                         do STM.atomicallyNodeT $ STM.writeTVarS STM.sharedMerklePeer Nothing
                            -- If we were not expecting this merkle block, do not
                            -- yield the merkle block and close the source
                            P.misbehaving pid ph STM.moderateDoS $
                                unwords
                                    [ "Peer sent us merkle block hash"
                                    , cs $ blockHashToHex $ headerHash mHead
                                    , "but we expected merkle block hash"
                                    , cs $ blockHashToHex bid
                                    ]
                            -- Not sure how to recover from this situation.
                            -- Disconnect the peer. TODO: Is there a way to recover
                            -- without buffering the whole batch in memory and
                            -- re-order it?
                            P.disconnectPeer pid ph
            -- The channel closed. Stop here.
            _ -> do
                $(logWarn) $
                    P.formatPid pid ph "Merkle channel closed unexpectedly"
                lift $ STM.atomicallyNodeT $ STM.writeTVarS STM.sharedMerklePeer Nothing

-- Build a source that that will check the order of the received merkle
-- blocks against the initial request. If merkle blocks are sent out of
-- order, the source will close and the peer will be flagged as
-- misbehaving. The source will also close once all the requested merkle
-- blocks have been received from the peer.
processTickles
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => STM.NodeT m ()
processTickles =
    forever $
    do $(logDebug) $ pack "Waiting for a block tickle ..."
       (pid, ph, tickle) <- STM.atomicallyNodeT waitTickle
       $(logInfo) $
           P.formatPid pid ph $
           unwords ["Received block tickle", cs $ blockHashToHex tickle]
       heightM <- fmap H.nodeBlockHeight <$> STM.runSqlNodeT (H.getBlockByHash tickle)
       case heightM of
           Just height -> do
               $(logInfo) $
                   P.formatPid pid ph $
                   unwords
                       [ "The block tickle"
                       , cs $ blockHashToHex tickle
                       , "is already connected"
                       ]
               updatePeerHeight pid ph height
           _ -> do
               $(logDebug) $
                   P.formatPid pid ph $
                   unwords
                       [ "The tickle"
                       , cs $ blockHashToHex tickle
                       , "is unknown. Requesting a peer header sync."
                       ]
               peerHeaderSyncFull pid ph `STM.catchAny`
                   const (P.disconnectPeer pid ph)
               newHeightM <-
                   fmap H.nodeBlockHeight <$> STM.runSqlNodeT (H.getBlockByHash tickle)
               case newHeightM of
                   Just height -> do
                       $(logInfo) $
                           P.formatPid pid ph $
                           unwords
                               [ "The block tickle"
                               , cs $ blockHashToHex tickle
                               , "was connected successfully"
                               ]
                       updatePeerHeight pid ph height
                   _ ->
                       $(logWarn) $
                       P.formatPid pid ph $
                       unwords
                           [ "Could not find the height of block tickle"
                           , cs $ blockHashToHex tickle
                           ]
  where
    updatePeerHeight pid ph height = do
        $(logInfo) $
            P.formatPid pid ph $ unwords ["Updating peer height to", show height]
        STM.atomicallyNodeT $
            do STM.modifyPeerSession pid $
                   \s ->
                        s
                        { STM.peerSessionHeight = height
                        }
               P.updateNetworkHeight

waitTickle :: STM.NodeT STM (STM.PeerId, STM.PeerHost, BlockHash)
waitTickle = do
    tickleChan <- asks STM.sharedTickleChan
    resM <- lift $ readTBMChan tickleChan
    case resM of
        Just res -> return res
        _        -> throw $ STM.NodeException "tickle channel closed unexpectedly"

syncedHeight
    :: MonadIO m
    => STM.NodeT m (Bool, Word32)
syncedHeight =
    STM.atomicallyNodeT $
    do synced <- areHeadersSynced
       ourHeight <- H.nodeBlockHeight <$> STM.readTVarS STM.sharedBestHeader
       return (synced, ourHeight)

headerSync
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => STM.NodeT m ()
headerSync = do
    $(logDebug) "Syncing more headers. Finding the best peer..."
    (pid, STM.PeerSession {..}) <-
        STM.atomicallyNodeT $
        do peers <- P.getPeersAtNetHeight
           case listToMaybe peers of
               Just res@(pid, _)
               -- Save the header syncing peer
                -> do
                   STM.writeTVarS STM.sharedHeaderPeer $ Just pid
                   return res
               _ -> lift retry
    $(logDebug) $
        P.formatPid pid peerSessionHost $
        unwords
            ["Found best header syncing peer with score", show peerSessionScore]
    -- Run a maximum of 10 header downloads with this peer.
    -- Then we re-evaluate the best peer
    continue <-
        STM.catchAny (peerHeaderSyncLimit pid peerSessionHost 10) $
        \e -> do
            $(logError) $ pack $ show e
            P.disconnectPeer pid peerSessionHost >> return True
    -- Reset the header syncing peer
    STM.atomicallyNodeT $ STM.writeTVarS STM.sharedHeaderPeer Nothing
    -- Check if we should continue the header sync
    if continue
        then headerSync
        else do
            (synced, ourHeight) <- syncedHeight
            if synced
                then $(logInfo) $
                        P.formatPid pid peerSessionHost $
                        unwords
                            [ "Block headers are in sync with the"
                            , "network at height"
                            , show ourHeight
                            ]
                else headerSync

-- Start the header sync
peerHeaderSyncLimit
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => STM.PeerId -> STM.PeerHost -> Int -> STM.NodeT m Bool
peerHeaderSyncLimit pid ph initLimit
    | initLimit < 1 = error "Limit must be at least 1"
    | otherwise = go initLimit Nothing
  where
    go limit prevM =
        peerHeaderSync pid ph prevM >>=
        \actionM ->
             case actionM of
                 Just action
                 -- If we received a side chain or a known chain, we want to
                 -- continue szncing from this peer even if the limit has been
                 -- reached.
                  ->
                     if limit > 1 || H.isSideChain action || H.isKnownChain action
                         then go (limit - 1) actionM
                              -- We got a Just, so we can continue the download from
                              -- this peer
                         else return True
                 _ -> return False

-- Sync all the headers from a given peer
peerHeaderSyncFull
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => STM.PeerId -> STM.PeerHost -> STM.NodeT m ()
peerHeaderSyncFull pid ph = go Nothing
  where
    go prevM =
        peerHeaderSync pid ph prevM >>=
        \actionM ->
             case actionM of
                 Just _ -> go actionM
                 Nothing -> do
                     (synced, ourHeight) <- syncedHeight
                     when synced $
                         $(logInfo) $
                         P.formatPid pid ph $
                         unwords
                             [ "Block headers are in sync with the"
                             , "network at height"
                             , show ourHeight
                             ]

areBlocksSynced :: BlockHash -> STM.NodeT STM Bool
areBlocksSynced walletHash = do
    headersSynced <- areHeadersSynced
    bestHeader <- STM.readTVarS STM.sharedBestHeader
    return $ headersSynced && walletHash == H.nodeHash bestHeader

-- Check if the block headers are synced with the network height
areHeadersSynced :: STM.NodeT STM Bool
areHeadersSynced = do
    ourHeight <- H.nodeBlockHeight <$> STM.readTVarS STM.sharedBestHeader
    netHeight <- STM.readTVarS STM.sharedNetworkHeight
    -- If netHeight == 0 then we did not connect to any peers yet
    return $ ourHeight >= netHeight && netHeight > 0

-- | Sync one batch of headers from the given peer. Accept the result of a
-- previous peerHeaderSync to correctly compute block locators in the
-- presence of side chains.
peerHeaderSync
    :: (MonadLoggerIO m, MonadBaseControl IO m)
    => STM.PeerId
    -> STM.PeerHost
    -> Maybe H.BlockChainAction
    -> STM.NodeT m (Maybe H.BlockChainAction)
peerHeaderSync pid ph prevM = do
    $(logDebug) $ P.formatPid pid ph "Waiting for the HeaderSync lock"
    -- Aquire the header syncing lock
    lock <- asks STM.sharedSyncLock
    liftBaseOp_ (Lock.with lock) $
        do best <- STM.atomicallyNodeT $ STM.readTVarS STM.sharedBestHeader
           -- Retrieve the block locator
           loc <-
               case prevM of
                   Just (H.KnownChain ns) -> do
                       $(logDebug) $
                           P.formatPid pid ph "Building a known chain locator"
                       STM.runSqlNodeT $ H.blockLocator $ last ns
                   Just (H.SideChain ns) -> do
                       $(logDebug) $
                           P.formatPid pid ph "Building a side chain locator"
                       STM.runSqlNodeT $ H.blockLocator $ last ns
                   Just (H.BestChain ns) -> do
                       $(logDebug) $
                           P.formatPid pid ph "Building a best chain locator"
                       STM.runSqlNodeT $ H.blockLocator $ last ns
                   Just (H.ChainReorg _ _ ns) -> do
                       $(logDebug) $ P.formatPid pid ph "Building a reorg locator"
                       STM.runSqlNodeT $ H.blockLocator $ last ns
                   Nothing -> do
                       $(logDebug) $
                           P.formatPid pid ph "Building a locator to best"
                       STM.runSqlNodeT $ H.blockLocator best
           $(logDebug) $
               P.formatPid pid ph $
               unwords
                   [ "Requesting headers with block locator of size"
                   , show $ length loc
                   , "Start block:"
                   , cs $ blockHashToHex $ head loc
                   , "End block:"
                   , cs $ blockHashToHex $ last loc
                   ]
           -- Send a GetHeaders message to the peer
           STM.atomicallyNodeT $
               P.sendMessage pid $ MGetHeaders $ GetHeaders 0x01 loc z
           $(logDebug) $ P.formatPid pid ph "Waiting 2 minutes for headers..."
           -- Wait 120 seconds for a response or time out
           continueE <-
               P.raceTimeout 120 (P.disconnectPeer pid ph) (waitHeaders best)
           -- Return True if we can continue syncing from this peer
           return $ either (const Nothing) id continueE
  where
    z = "0000000000000000000000000000000000000000000000000000000000000000"
    -- Wait for the headers to be available
    waitHeaders best = do
        (rPid, headers) <- STM.atomicallyNodeT $ STM.takeTMVarS STM.sharedHeaders
        if rPid == pid
            then processHeaders best headers
            else waitHeaders best
    processHeaders _ (Headers []) = do
        $(logDebug) $
            P.formatPid
                pid
                ph
                "Received empty headers. Finished downloading headers."
        -- Do not continue the header download
        return Nothing
    processHeaders best (Headers hs) = do
        $(logDebug) $
            P.formatPid pid ph $
            unwords
                [ "Received"
                , show $ length hs
                , "headers."
                , "Start blocks:"
                , cs $ blockHashToHex $ headerHash $ fst $ head hs
                , "End blocks:"
                , cs $ blockHashToHex $ headerHash $ fst $ last hs
                ]
        now <- round <$> liftIO getPOSIXTime
        actionE <- STM.runSqlNodeT $ H.connectHeaders best (map fst hs) now
        case actionE of
            Left err -> do
                P.misbehaving pid ph STM.severeDoS err
                return Nothing
            Right action ->
                case H.actionNodes action of
                    [] -> do
                        $(logWarn) $
                            P.formatPid pid ph $
                            unwords
                                [ "Received an empty blockchain action:"
                                , show action
                                ]
                        return Nothing
                    nodes -> do
                        $(logDebug) $
                            P.formatPid pid ph $
                            unwords
                                [ "Received"
                                , show $ length nodes
                                , "nodes in the action"
                                ]
                        let height = H.nodeBlockHeight $ last nodes
                        case action of
                            H.KnownChain _ ->
                                $(logInfo) $
                                P.formatPid pid ph $
                                unwords
                                    [ "KnownChain headers received"
                                    , "up to height"
                                    , show height
                                    ]
                            H.SideChain _ ->
                                $(logInfo) $
                                P.formatPid pid ph $
                                unwords
                                    [ "SideChain headers connected successfully"
                                    , "up to height"
                                    , show height
                                    ]
                            -- Headers extend our current best head
                            _ -> do
                                $(logInfo) $
                                    P.formatPid pid ph $
                                    unwords
                                        [ "Best headers connected successfully"
                                        , "up to height"
                                        , show height
                                        ]
                                STM.atomicallyNodeT $
                                    STM.writeTVarS STM.sharedBestHeader $ last nodes
                        -- If we received less than 2000 headers, we are done
                        -- syncing from this peer and we return Nothing.
                        return $
                            if length hs < 2000
                                then Nothing
                                else Just action

nodeStatus :: STM.NodeT STM STM.NodeStatus
nodeStatus = do
    nodeStatusPeers <- mapM peerStatus =<< P.getPeers
    STM.SharedNodeState {..} <- ask
    lift $
        do best <- readTVar sharedBestBlock
           header <- readTVar sharedBestHeader
           let nodeStatusBestBlock = H.nodeHash best
               nodeStatusBestBlockHeight = H.nodeBlockHeight best
               nodeStatusBestHeader = H.nodeHash header
               nodeStatusBestHeaderHeight = H.nodeBlockHeight header
           nodeStatusNetworkHeight <- readTVar sharedNetworkHeight
           nodeStatusBloomSize <-
               maybe 0 (S.length . bloomData . fst) <$> readTVar sharedBloomFilter
           nodeStatusHeaderPeer <- fmap (hashUnique . STM.peerId) <$> readTVar sharedHeaderPeer
           nodeStatusMerklePeer <- fmap (hashUnique . STM.peerId) <$> readTVar sharedMerklePeer
           nodeStatusHaveHeaders <- not <$> isEmptyTMVar sharedHeaders
           nodeStatusHaveTickles <- not <$> isEmptyTBMChan sharedTickleChan
           nodeStatusHaveTxs <- not <$> isEmptyTBMChan sharedTxChan
           nodeStatusGetData <- M.keys <$> readTVar sharedTxGetData
           nodeStatusRescan <- tryReadTMVar sharedRescan
           nodeStatusMempool <- M.size <$> readTVar sharedMempool
           nodeStatusSyncLock <- locked sharedSyncLock
           return
               STM.NodeStatus
               { ..
               }

peerStatus :: (STM.PeerId, STM.PeerSession) -> STM.NodeT STM STM.PeerStatus
peerStatus (pid, STM.PeerSession {..}) = do
    hostM <- STM.getHostSession peerSessionHost
    let peerStatusPeerId = hashUnique . STM.peerId $ pid
        peerStatusHost = peerSessionHost
        peerStatusConnected = peerSessionConnected
        peerStatusHeight = peerSessionHeight
        peerStatusProtocol = version <$> peerSessionVersion
        peerStatusUserAgent = C.unpack . getVarString . userAgent <$> peerSessionVersion
        peerStatusPing = show <$> peerSessionScore
        peerStatusDoSScore = STM.peerHostSessionScore <$> hostM
        peerStatusLog = STM.peerHostSessionLog <$> hostM
        peerStatusReconnectTimer = STM.peerHostSessionReconnect <$> hostM
    lift $
        do peerStatusHaveMerkles <- not <$> isEmptyTBMChan peerSessionMerkleChan
           peerStatusHaveMessage <- not <$> isEmptyTBMChan peerSessionChan
           peerStatusPingNonces <- readTVar peerSessionPings
           return
               STM.PeerStatus
               { ..
               }
