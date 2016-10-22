{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}

module Network.Haskoin.Wallet.Server.Handler
       ( Handler
       , HandlerSession (..)
       , adjustFCTime
       , deleteTxIdR
       , getAccountR
       , getAccountsR
       , getAddressR
       , getAddressesR
       , getAddressesUnusedR
       , getAddrTxsR
       , getBalanceR
       , getDeadR
       , getOfflineTxR
       , getPendingR
       , getSyncR
       , getTxR
       , getTxsR
       , postAccountGapR
       , postAccountKeysR
       , postAccountRenameR
       , postAccountsR
       , postAddressesR
       , postNodeR
       , postOfflineTxR
       , postTxsR
       , putAddressR
       , runDBPool
       , runHandler
       ) where

import           Control.Arrow                      (first)
import           Control.Concurrent.STM.TBMChan     (TBMChan)
import           Control.Exception                  (SomeException (..),
                                                     tryJust)
import           Control.Monad                      (liftM, unless, when)
import           Control.Monad.Base                 (MonadBase)
import           Control.Monad.Catch                (MonadThrow, throwM)
import           Control.Monad.Logger               (MonadLoggerIO, logError,
                                                     logInfo)
import           Control.Monad.Reader               (ReaderT, asks, runReaderT)
import           Control.Monad.Trans                (MonadIO, lift, liftIO)
import           Control.Monad.Trans.Control        (MonadBaseControl)
import           Control.Monad.Trans.Resource       (MonadResource)
import           Data.Aeson                         (Value (..), toJSON)
import qualified Data.Map.Strict                    as M (elems, fromList,
                                                          intersectionWith)
import           Data.String.Conversions            (cs)
import           Data.Text                          (Text, pack, unpack)
import           Data.Word                          (Word32)
import           Database.Esqueleto                 (Entity (..), SqlPersistT)
import           Database.Persist.Sql               (ConnectionPool,
                                                     SqlPersistM,
                                                     runSqlPersistMPool,
                                                     runSqlPool)
import           Network.Haskoin.Block              (BlockHash, blockHashToHex)
import           Network.Haskoin.Crypto             (KeyIndex, XPrvKey, XPubKey,
                                                     addrToBase58)
import           Network.Haskoin.Node.BlockChain    (broadcastTxs, nodeStatus,
                                                     rescanTs)
import           Network.Haskoin.Node.HeaderTree    (BlockHeight, Timestamp,
                                                     nodeBlockHeight, nodeHash,
                                                     nodePrev)
import           Network.Haskoin.Node.Peer          (sendBloomFilter)
import           Network.Haskoin.Node.STM           (NodeT, SharedNodeState,
                                                     atomicallyNodeT, runNodeT)
import           Network.Haskoin.Transaction        (Tx, TxHash, txHash,
                                                     txHashToHex, verifyStdTx)
import           Network.Haskoin.Wallet.Accounts    (accounts, addAccountKeys,
                                                     addressList, firstAddrTime,
                                                     generateAddrs, getAccount,
                                                     getAddress, getBloomFilter,
                                                     isCompleteAccount,
                                                     newAccount, renameAccount,
                                                     setAccountGap,
                                                     setAddrLabel,
                                                     unusedAddresses)
import           Network.Haskoin.Wallet.Block       (blockTxs, mainChain)
import           Network.Haskoin.Wallet.Model       (AccountId, WalletTx (..),
                                                     toJsonAccount, toJsonAddr,
                                                     toJsonTx, walletAddrIndex,
                                                     walletTxAccount,
                                                     walletTxConfidence)
import           Network.Haskoin.Wallet.Settings    (Config (configMode),
                                                     SPVMode (SPVOnline))
import           Network.Haskoin.Wallet.Transaction (accTxsFromBlock,
                                                     accountBalance, addrTxs,
                                                     addressBalances,
                                                     createWalletTx, deleteTx,
                                                     getAccountTx,
                                                     getOfflineTxData, importTx,
                                                     resetRescan, signAccountTx,
                                                     signOfflineTx, txs,
                                                     walletBestBlock)
import qualified Network.Haskoin.Wallet.Types       as WT

type Handler m = ReaderT HandlerSession m

data HandlerSession = HandlerSession
    { handlerConfig    :: !Config
    , handlerPool      :: !ConnectionPool
    , handlerNodeState :: !(Maybe SharedNodeState)
    , handlerNotifChan :: !(TBMChan WT.Notif)
    }

runHandler
    :: Monad m
    => Handler m a -> HandlerSession -> m a
runHandler = runReaderT

runDB
    :: MonadBaseControl IO m
    => SqlPersistT m a -> Handler m a
runDB action = asks handlerPool >>= lift . runDBPool action

runDBPool
    :: MonadBaseControl IO m
    => SqlPersistT m a -> ConnectionPool -> m a
runDBPool = runSqlPool

tryDBPool
    :: MonadLoggerIO m
    => ConnectionPool -> SqlPersistM a -> m (Maybe a)
tryDBPool pool action = do
    resE <- liftIO $ tryJust f $ runSqlPersistMPool action pool
    case resE of
        Right res -> return $ Just res
        Left err -> do
            $(logError) $ pack $ unwords ["A database error occured:", err]
            return Nothing
  where
    f (SomeException e) = Just $ show e

runNode
    :: MonadIO m
    => NodeT m a -> Handler m a
runNode action = do
    nodeStateM <- asks handlerNodeState
    case nodeStateM of
        Just nodeState -> lift $ runNodeT action nodeState
        _              -> error "runNode: No node state available"

{- Server Handlers -}
getAccountsR
    :: (MonadLoggerIO m
       ,MonadBaseControl IO m
       ,MonadBase IO m
       ,MonadThrow m
       ,MonadResource m)
    => WT.ListRequest -> Handler m (Maybe Value)
getAccountsR lq@WT.ListRequest {..} = do
    $(logInfo) $
        format $
        unlines
            [ "GetAccountsR"
            , "  Offset      : " ++ show listOffset
            , "  Limit       : " ++ show listLimit
            , "  Reversed    : " ++ show listReverse
            ]
    (accs, cnt) <- runDB $ accounts lq
    return $ Just $ toJSON $ WT.ListResult (map (toJsonAccount Nothing) accs) cnt

postAccountsR
    :: (MonadResource m, MonadThrow m, MonadLoggerIO m, MonadBaseControl IO m)
    => WT.NewAccount -> Handler m (Maybe Value)
postAccountsR newAcc@WT.NewAccount {..} = do
    $(logInfo) $
        format $
        unlines
            [ "PostAccountsR"
            , "  Account name: " ++ unpack newAccountName
            , "  Account type: " ++ show newAccountType
            ]
    (Entity _ newAcc', mnemonicM) <- runDB $ newAccount newAcc
    -- Update the bloom filter if the account is complete
    whenOnline $ when (isCompleteAccount newAcc') updateNodeFilter
    return $ Just $ toJSON $ toJsonAccount mnemonicM newAcc'

postAccountRenameR
    :: (MonadResource m, MonadThrow m, MonadLoggerIO m, MonadBaseControl IO m)
    => WT.AccountName -> WT.AccountName -> Handler m (Maybe Value)
postAccountRenameR oldName newName = do
    $(logInfo) $
        format $
        unlines
            [ "PostAccountRenameR"
            , "  Account name: " ++ unpack oldName
            , "  New name    : " ++ unpack newName
            ]
    newAcc <-
        runDB $
        do accE <- getAccount oldName
           renameAccount accE newName
    return $ Just $ toJSON $ toJsonAccount Nothing newAcc

getAccountR
    :: (MonadLoggerIO m, MonadBaseControl IO m, MonadThrow m)
    => WT.AccountName -> Handler m (Maybe Value)
getAccountR name = do
    $(logInfo) $
        format $ unlines ["GetAccountR", "  Account name: " ++ unpack name]
    Entity _ acc <- runDB $ getAccount name
    return $ Just $ toJSON $ toJsonAccount Nothing acc

postAccountKeysR
    :: (MonadResource m, MonadThrow m, MonadLoggerIO m, MonadBaseControl IO m)
    => WT.AccountName -> [XPubKey] -> Handler m (Maybe Value)
postAccountKeysR name keys = do
    $(logInfo) $
        format $
        unlines
            [ "PostAccountKeysR"
            , "  Account name: " ++ unpack name
            , "  Key count   : " ++ show (length keys)
            ]
    newAcc <-
        runDB $
        do accE <- getAccount name
           addAccountKeys accE keys
    -- Update the bloom filter if the account is complete
    whenOnline $ when (isCompleteAccount newAcc) updateNodeFilter
    return $ Just $ toJSON $ toJsonAccount Nothing newAcc

postAccountGapR
    :: (MonadLoggerIO m
       ,MonadBaseControl IO m
       ,MonadBase IO m
       ,MonadThrow m
       ,MonadResource m)
    => WT.AccountName -> WT.SetAccountGap -> Handler m (Maybe Value)
postAccountGapR name (WT.SetAccountGap gap) = do
    $(logInfo) $
        format $
        unlines
            [ "PostAccountGapR"
            , "  Account name: " ++ unpack name
            , "  New gap size: " ++ show gap
            ]
    -- Update the gap
    Entity _ newAcc <-
        runDB $
        do accE <- getAccount name
           setAccountGap accE gap
    -- Update the bloom filter
    whenOnline updateNodeFilter
    return $ Just $ toJSON $ toJsonAccount Nothing newAcc

getAddressesR
    :: (MonadLoggerIO m, MonadBaseControl IO m, MonadThrow m)
    => WT.AccountName
    -> WT.AddressType
    -> Word32
    -> Bool
    -> WT.ListRequest
    -> Handler m (Maybe Value)
getAddressesR name addrType minConf offline listReq = do
    $(logInfo) $
        format $
        unlines
            [ "GetAddressesR"
            , "  Account name: " ++ unpack name
            , "  Address type: " ++ show addrType
            , "  Start index : " ++ show (WT.listOffset listReq)
            , "  Reversed    : " ++ show (WT.listReverse listReq)
            , "  MinConf     : " ++ show minConf
            , "  Offline     : " ++ show offline
            ]
    (res, bals, cnt) <-
        runDB $
        do accE <- getAccount name
           (res, cnt) <- addressList accE addrType listReq
           case res of
               [] -> return (res, [], cnt)
               _ -> do
                   let is = map walletAddrIndex res
                       (iMin, iMax) = (minimum is, maximum is)
                   bals <- addressBalances accE iMin iMax addrType minConf offline
                   return (res, bals, cnt)
    -- Join addresses and balances together
    let g (addr, bal) = toJsonAddr addr (Just bal)
        addrBals = map g $ M.elems $ joinAddrs res bals
    return $ Just $ toJSON $ WT.ListResult addrBals cnt
  where
    joinAddrs addrs bals =
        let f addr = (walletAddrIndex addr, addr)
        in M.intersectionWith (,) (M.fromList $ map f addrs) (M.fromList bals)

getAddressesUnusedR
    :: (MonadLoggerIO m, MonadBaseControl IO m, MonadThrow m)
    => WT.AccountName -> WT.AddressType -> WT.ListRequest -> Handler m (Maybe Value)
getAddressesUnusedR name addrType lq@WT.ListRequest {..} = do
    $(logInfo) $
        format $
        unlines
            [ "GetAddressesUnusedR"
            , "  Account name: " ++ unpack name
            , "  Address type: " ++ show addrType
            , "  Offset      : " ++ show listOffset
            , "  Limit       : " ++ show listLimit
            , "  Reversed    : " ++ show listReverse
            ]
    (addrs, cnt) <-
        runDB $
        do accE <- getAccount name
           unusedAddresses accE addrType lq
    return $ Just $ toJSON $ WT.ListResult (map (`toJsonAddr` Nothing) addrs) cnt

getAddressR
    :: (MonadLoggerIO m, MonadBaseControl IO m, MonadThrow m)
    => WT.AccountName
    -> KeyIndex
    -> WT.AddressType
    -> Word32
    -> Bool
    -> Handler m (Maybe Value)
getAddressR name i addrType minConf offline = do
    $(logInfo) $
        format $
        unlines
            [ "GetAddressR"
            , "  Account name: " ++ unpack name
            , "  Index       : " ++ show i
            , "  Address type: " ++ show addrType
            ]
    (addr, balM) <-
        runDB $
        do accE <- getAccount name
           addrE <- getAddress accE addrType i
           bals <- addressBalances accE i i addrType minConf offline
           return $
               case bals of
                   ((_, bal):_) -> (entityVal addrE, Just bal)
                   _            -> (entityVal addrE, Nothing)
    return $ Just $ toJSON $ toJsonAddr addr balM

putAddressR
    :: (MonadLoggerIO m, MonadBaseControl IO m, MonadThrow m)
    => WT.AccountName
    -> KeyIndex
    -> WT.AddressType
    -> WT.AddressLabel
    -> Handler m (Maybe Value)
putAddressR name i addrType (WT.AddressLabel label) = do
    $(logInfo) $
        format $
        unlines
            [ "PutAddressR"
            , "  Account name: " ++ unpack name
            , "  Index       : " ++ show i
            , "  Label       : " ++ unpack label
            ]
    newAddr <-
        runDB $
        do accE <- getAccount name
           setAddrLabel accE i addrType label
    return $ Just $ toJSON $ toJsonAddr newAddr Nothing

postAddressesR
    :: (MonadLoggerIO m
       ,MonadBaseControl IO m
       ,MonadThrow m
       ,MonadBase IO m
       ,MonadResource m)
    => WT.AccountName -> KeyIndex -> WT.AddressType -> Handler m (Maybe Value)
postAddressesR name i addrType = do
    $(logInfo) $
        format $
        unlines
            [ "PostAddressesR"
            , "  Account name: " ++ unpack name
            , "  Index       : " ++ show i
            ]
    cnt <-
        runDB $
        do accE <- getAccount name
           generateAddrs accE addrType i
    -- Update the bloom filter
    whenOnline updateNodeFilter
    return $ Just $ toJSON cnt

getTxs
    :: (MonadLoggerIO m, MonadBaseControl IO m, MonadThrow m)
    => WT.AccountName
    -> WT.ListRequest
    -> String
    -> (AccountId -> WT.ListRequest -> SqlPersistT m ([WalletTx], Word32))
    -> Handler m (Maybe Value)
getTxs name lq@WT.ListRequest {..} cmd f = do
    $(logInfo) $
        format $
        unlines
            [ cmd
            , "  Account name: " ++ unpack name
            , "  Offset      : " ++ show listOffset
            , "  Limit       : " ++ show listLimit
            , "  Reversed    : " ++ show listReverse
            ]
    (res, cnt, bb) <-
        runDB $
        do Entity ai _ <- getAccount name
           bb <- walletBestBlock
           (res, cnt) <- f ai lq
           return (res, cnt, bb)
    return $ Just $ toJSON $ WT.ListResult (map (g bb) res) cnt
  where
    g bb = toJsonTx name (Just bb)

getTxsR
    :: (MonadLoggerIO m, MonadBaseControl IO m, MonadThrow m)
    => WT.AccountName -> WT.ListRequest -> Handler m (Maybe Value)
getTxsR name lq = getTxs name lq "GetTxsR" (txs Nothing)

getPendingR
    :: (MonadLoggerIO m, MonadBaseControl IO m, MonadThrow m)
    => WT.AccountName -> WT.ListRequest -> Handler m (Maybe Value)
getPendingR name lq = getTxs name lq "GetPendingR" (txs (Just WT.TxPending))

getDeadR
    :: (MonadLoggerIO m, MonadBaseControl IO m, MonadThrow m)
    => WT.AccountName -> WT.ListRequest -> Handler m (Maybe Value)
getDeadR name lq = getTxs name lq "GetDeadR" (txs (Just WT.TxDead))

getAddrTxsR
    :: (MonadLoggerIO m, MonadBaseControl IO m, MonadThrow m)
    => WT.AccountName
    -> KeyIndex
    -> WT.AddressType
    -> WT.ListRequest
    -> Handler m (Maybe Value)
getAddrTxsR name index addrType lq@WT.ListRequest {..} = do
    $(logInfo) $
        format $
        unlines
            [ "GetAddrTxsR"
            , "  Account name : " ++ unpack name
            , "  Address index: " ++ show index
            , "  Address type : " ++ show addrType
            , "  Offset       : " ++ show listOffset
            , "  Limit        : " ++ show listLimit
            , "  Reversed     : " ++ show listReverse
            ]
    (res, cnt, bb) <-
        runDB $
        do accE <- getAccount name
           addrE <- getAddress accE addrType index
           bb <- walletBestBlock
           (res, cnt) <- addrTxs accE addrE lq
           return (res, cnt, bb)
    return $ Just $ toJSON $ WT.ListResult (map (f bb) res) cnt
  where
    f bb = toJsonTx name (Just bb)

postTxsR
    :: (MonadLoggerIO m
       ,MonadBaseControl IO m
       ,MonadBase IO m
       ,MonadThrow m
       ,MonadResource m)
    => WT.AccountName -> Maybe XPrvKey -> WT.TxAction -> Handler m (Maybe Value)
postTxsR name masterM action = do
    (accE@(Entity ai _), bb) <-
        runDB $
        do accE <- getAccount name
           bb <- walletBestBlock
           return (accE, bb)
    notif <- asks handlerNotifChan
    (txRes, newAddrs) <-
        case action of
            WT.CreateTx rs fee minconf rcptFee sign -> do
                $(logInfo) $
                    format $
                    unlines
                        [ "PostTxsR CreateTx"
                        , "  Account name: " ++ unpack name
                        , "  Recipients  : " ++
                          show (map (first addrToBase58) rs)
                        , "  Fee         : " ++ show fee
                        , "  Minconf     : " ++ show minconf
                        , "  Rcpt. Fee   : " ++ show rcptFee
                        , "  Sign        : " ++ show sign
                        ]
                runDB $
                    createWalletTx
                        accE
                        (Just notif)
                        masterM
                        rs
                        fee
                        minconf
                        rcptFee
                        sign
            WT.ImportTx tx -> do
                $(logInfo) $
                    format $
                    unlines
                        [ "PostTxsR ImportTx"
                        , "  Account name: " ++ unpack name
                        , "  TxId        : " ++ cs (txHashToHex (txHash tx))
                        ]
                runDB $
                    do (res, newAddrs) <- importTx tx (Just notif) ai
                       case filter ((== ai) . walletTxAccount) res of
                           (txRes:_) -> return (txRes, newAddrs)
                           _ ->
                               throwM $
                               WT.WalletException
                                   "Could not import the transaction"
            WT.SignTx txid -> do
                $(logInfo) $
                    format $
                    unlines
                        [ "PostTxsR SignTx"
                        , "  Account name: " ++ unpack name
                        , "  TxId        : " ++ cs (txHashToHex txid)
                        ]
                runDB $
                    do (res, newAddrs) <-
                           signAccountTx accE (Just notif) masterM txid
                       case filter ((== ai) . walletTxAccount) res of
                           (txRes:_) -> return (txRes, newAddrs)
                           _ ->
                               throwM $
                               WT.WalletException
                                   "Could not import the transaction"
    whenOnline $
    -- Update the bloom filter
        do unless (null newAddrs) updateNodeFilter
           -- If the transaction is pending, broadcast it to the network
           when (walletTxConfidence txRes == WT.TxPending) $
               runNode $ broadcastTxs [walletTxHash txRes]
    return $ Just $ toJSON $ toJsonTx name (Just bb) txRes

getTxR
    :: (MonadLoggerIO m, MonadBaseControl IO m, MonadThrow m)
    => WT.AccountName -> TxHash -> Handler m (Maybe Value)
getTxR name txid = do
    $(logInfo) $
        format $
        unlines
            [ "GetTxR"
            , "  Account name: " ++ unpack name
            , "  TxId        : " ++ cs (txHashToHex txid)
            ]
    (res, bb) <-
        runDB $
        do Entity ai _ <- getAccount name
           bb <- walletBestBlock
           res <- getAccountTx ai txid
           return (res, bb)
    return $ Just $ toJSON $ toJsonTx name (Just bb) res

deleteTxIdR
    :: (MonadLoggerIO m, MonadThrow m, MonadBaseControl IO m)
    => TxHash -> Handler m (Maybe Value)
deleteTxIdR txid = do
    $(logInfo) $
        format $ unlines ["DeleteTxR", "  TxId: " ++ cs (txHashToHex txid)]
    runDB $ deleteTx txid
    return Nothing

getBalanceR
    :: (MonadLoggerIO m, MonadBaseControl IO m, MonadThrow m)
    => WT.AccountName -> Word32 -> Bool -> Handler m (Maybe Value)
getBalanceR name minconf offline = do
    $(logInfo) $
        format $
        unlines
            [ "GetBalanceR"
            , "  Account name: " ++ unpack name
            , "  Minconf     : " ++ show minconf
            , "  Offline     : " ++ show offline
            ]
    bal <-
        runDB $
        do Entity ai _ <- getAccount name
           accountBalance ai minconf offline
    return $ Just $ toJSON bal

getOfflineTxR
    :: (MonadLoggerIO m
       ,MonadBaseControl IO m
       ,MonadBase IO m
       ,MonadThrow m
       ,MonadResource m)
    => WT.AccountName -> TxHash -> Handler m (Maybe Value)
getOfflineTxR accountName txid = do
    $(logInfo) $
        format $
        unlines
            [ "GetOfflineTxR"
            , "  Account name: " ++ unpack accountName
            , "  TxId        : " ++ cs (txHashToHex txid)
            ]
    (dat, _) <-
        runDB $
        do Entity ai _ <- getAccount accountName
           getOfflineTxData ai txid
    return $ Just $ toJSON dat

postOfflineTxR
    :: (MonadLoggerIO m
       ,MonadBaseControl IO m
       ,MonadBase IO m
       ,MonadThrow m
       ,MonadResource m)
    => WT.AccountName
    -> Maybe XPrvKey
    -> Tx
    -> [WT.CoinSignData]
    -> Handler m (Maybe Value)
postOfflineTxR accountName masterM tx signData = do
    $(logInfo) $
        format $
        unlines
            [ "PostTxsR SignOfflineTx"
            , "  Account name: " ++ unpack accountName
            , "  TxId        : " ++ cs (txHashToHex (txHash tx))
            ]
    Entity _ acc <- runDB $ getAccount accountName
    let signedTx = signOfflineTx acc masterM tx signData
        complete = verifyStdTx signedTx $ map toDat signData
        toDat WT.CoinSignData {..} = (coinSignScriptOutput, coinSignOutPoint)
    return $ Just $ toJSON $ WT.TxCompleteRes signedTx complete

postNodeR
    :: (MonadLoggerIO m, MonadBaseControl IO m, MonadThrow m)
    => WT.NodeAction -> Handler m (Maybe Value)
postNodeR action =
    case action of
        WT.NodeActionRescan tM -> do
            t <-
                case tM of
                    Just t -> return $ adjustFCTime t
                    Nothing -> do
                        timeM <- runDB firstAddrTime
                        maybe err (return . adjustFCTime) timeM
            $(logInfo) $
                format $ unlines ["NodeR Rescan", "  Timestamp: " ++ show t]
            whenOnline $
                do runDB resetRescan
                   runNode $ atomicallyNodeT $ rescanTs t
            return $ Just $ toJSON $ WT.RescanRes t
        WT.NodeActionStatus -> do
            status <- runNode $ atomicallyNodeT nodeStatus
            return $ Just $ toJSON status
  where
    err = throwM $ WT.WalletException "No keys have been generated in the wallet"

getSyncR
    :: (MonadThrow m, MonadLoggerIO m, MonadBaseControl IO m)
    => WT.AccountName
    -> Either BlockHeight BlockHash
    -> WT.ListRequest
    -> Handler m (Maybe Value)
getSyncR acc blockE lq@WT.ListRequest {..} =
    runDB $
    do $(logInfo) $
           format $
           unlines
               [ "GetSyncR"
               , "  Account name: " ++ cs acc
               , "  Block       : " ++ showBlock
               , "  Offset      : " ++ show listOffset
               , "  Limit       : " ++ show listLimit
               , "  Reversed    : " ++ show listReverse
               ]
       WT.ListResult nodes cnt <- mainChain blockE lq
       case nodes of
           [] -> return $ Just $ toJSON $ WT.ListResult ([] :: [()]) cnt
           b:_ -> do
               Entity ai _ <- getAccount acc
               ts <-
                   accTxsFromBlock
                       ai
                       (nodeBlockHeight b)
                       (fromIntegral $ length nodes)
               let bts = blockTxs nodes ts
               return $ Just $ toJSON $ WT.ListResult (map f bts) cnt
  where
    f (block, txs') =
        WT.JsonSyncBlock
        { jsonSyncBlockHash = nodeHash block
        , jsonSyncBlockHeight = nodeBlockHeight block
        , jsonSyncBlockPrev = nodePrev block
        , jsonSyncBlockTxs = map (toJsonTx acc Nothing) txs'
        }
    showBlock =
        case blockE of
            Left e  -> show e
            Right b -> cs $ blockHashToHex b

{- Helpers -}
whenOnline
    :: Monad m
    => Handler m () -> Handler m ()
whenOnline handler = do
    mode <- configMode `liftM` asks handlerConfig
    when (mode == SPVOnline) handler

updateNodeFilter
    :: (MonadBaseControl IO m, MonadLoggerIO m, MonadThrow m)
    => Handler m ()
updateNodeFilter = do
    $(logInfo) $ format "Sending a new bloom filter"
    (bloom, elems, _) <- runDB getBloomFilter
    runNode $ atomicallyNodeT $ sendBloomFilter bloom elems

adjustFCTime :: Timestamp -> Timestamp
adjustFCTime ts = fromInteger $ max 0 $ toInteger ts - 86400 * 7

format :: String -> Text
format str = pack $ "[ZeroMQ] " ++ str
