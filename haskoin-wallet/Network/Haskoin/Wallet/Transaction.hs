{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards       #-}

module Network.Haskoin.Wallet.Transaction
       ( txs
       , addrTxs
       , accTxsFromBlock
       , getTx
       , getAccountTx
       , importTx
       , importNetTx
       , signAccountTx
       , createWalletTx
       , signOfflineTx
       , getOfflineTxData
       , killTxs
       , reviveTx
       , getPendingTxs
       , deleteTx
       , importMerkles
       , walletBestBlock
       , spendableCoins
       , accountBalance
       , addressBalances
       , resetRescan
       , InCoinData(..)
       ) where

-- *Database transactions
-- *Database blocks
-- *Database coins and balances
-- *Rescan
-- *Helpers
import           Control.Arrow                   (second)
import           Control.Concurrent.STM          (atomically)
import           Control.Concurrent.STM.TBMChan  (TBMChan, writeTBMChan)
import           Control.Exception               (throw, throwIO)
import           Control.Monad                   (forM, forM_, unless, when)
import           Control.Monad.Base              (MonadBase)
import           Control.Monad.Catch             (MonadThrow, throwM)
import           Control.Monad.Trans             (MonadIO, liftIO)
import           Control.Monad.Trans.Resource    (MonadResource)
import           Data.Either                     (rights)
import           Data.List                       (find, nub, nubBy, (\\))
import qualified Data.Map.Strict                 as M (Map, fromListWith, map,
                                                       toList, unionWith)
import           Data.Maybe                      (fromMaybe, isJust, isNothing,
                                                  listToMaybe, mapMaybe)
import           Data.String.Conversions         (cs)
import           Data.Time                       (UTCTime, getCurrentTime)
import           Data.Word                       (Word32, Word64)
import           Database.Esqueleto              (Entity (..), InnerJoin (..),
                                                  LeftOuterJoin (..), OrderBy,
                                                  SqlExpr, SqlPersistT,
                                                  SqlQuery, Value (..), asc,
                                                  case_, coalesceDefault, count,
                                                  countDistinct, countRows,
                                                  delete, desc, distinct, else_,
                                                  from, get, getBy, groupBy,
                                                  in_, just, limit, not_, on,
                                                  orderBy, replace, select, set,
                                                  sub_select, sum_, then_,
                                                  unValue, update, val, valList,
                                                  when_, where_, (!=.), (&&.),
                                                  (-.), (<.), (<=.), (=.),
                                                  (==.), (>=.), (?.), (^.),
                                                  (||.))
import qualified Database.Esqueleto              as E (isNothing)
import qualified Database.Persist                as P (Filter, deleteWhere,
                                                       insertBy, selectFirst)
import           Network.Haskoin.Block           (BlockHash, headerHash)
import           Network.Haskoin.Constants       (genesisHeader)
import qualified Network.Haskoin.Crypto          as CY
import           Network.Haskoin.Node.HeaderTree (BlockChainAction (..),
                                                  BlockHeight, isBestChain,
                                                  isChainReorg, nodeBlockHeight,
                                                  nodeHash, nodePrev,
                                                  nodeTimestamp)
import           Network.Haskoin.Node.STM        (MerkleTxs)
import           Network.Haskoin.Script          (ScriptOutput, SigHash (..),
                                                  decodeInputBS, decodeOutputBS,
                                                  inputAddress, outputAddress)
import qualified Network.Haskoin.Transaction     as TX
import           Network.Haskoin.Util            (eitherToMaybe)
import           Network.Haskoin.Wallet.Accounts (getPathRedeem,
                                                  isMultisigAccount,
                                                  subSelectAddrCount,
                                                  unusedAddresses, useAddress)
import qualified Network.Haskoin.Wallet.Model    as M
import           Network.Haskoin.Wallet.Types

-- Input coin type with transaction and address information
data InCoinData = InCoinData
    { inCoinDataCoin :: !(Entity M.WalletCoin)
    , inCoinDataTx   :: !M.WalletTx
    , inCoinDataAddr :: !M.WalletAddr
    }

instance TX.Coin InCoinData where
    coinValue (InCoinData (Entity _ c) _ _) = M.walletCoinValue c

-- Output coin type with address information
data OutCoinData = OutCoinData
    { outCoinDataAddr   :: !(Entity M.WalletAddr)
    , outCoinDataPos    :: !CY.KeyIndex
    , outCoinDataValue  :: !Word64
    , outCoinDataScript :: !ScriptOutput
    }

{- List transactions -}
-- | Get transactions.
txs
    :: MonadIO m
    => Maybe TxConfidence
    -> M.AccountId -- ^ Account ID
    -> ListRequest -- ^ List request
    -> SqlPersistT m ([M.WalletTx], Word32) -- ^ List result
txs conf ai ListRequest {..} = do
    [cnt] <-
        fmap (map unValue) $
        select $
        from $
        \t -> do
            cond t
            return countRows
    when (listOffset > 0 && listOffset >= cnt) $
        throw $ WalletException "Offset beyond end of data set"
    res <-
        fmap (map entityVal) $
        select $
        from $
        \t -> do
            cond t
            orderBy [order (t ^. M.WalletTxId)]
            limitOffset listLimit listOffset
            return t
    return (res, cnt)
  where
    account t = t ^. M.WalletTxAccount ==. val ai
    cond t =
        where_ $
        case conf of
            Just n  -> account t &&. t ^. M.WalletTxConfidence ==. val n
            Nothing -> account t
    order =
        if listReverse
            then asc
            else desc

{- List transactions for an account and address -}
addrTxs
    :: MonadIO m
    => Entity M.Account -- ^ Account entity
    -> Entity M.WalletAddr -- ^ Address entity
    -> ListRequest -- ^ List request
    -> SqlPersistT m ([M.WalletTx], Word32)
addrTxs (Entity ai _) (Entity addrI M.WalletAddr {..}) ListRequest {..} = do
    let joinSpentCoin c2 s =
            c2 ?. M.WalletCoinAccount ==. s ?. M.SpentCoinAccount &&. c2 ?. M.WalletCoinHash ==.
            s ?.
            M.SpentCoinHash &&.
            c2 ?.
            M.WalletCoinPos ==.
            s ?.
            M.SpentCoinPos &&.
            c2 ?.
            M.WalletCoinAddr ==.
            just (val addrI)
        joinSpent s t = s ?. M.SpentCoinSpendingTx ==. just (t ^. M.WalletTxId)
        joinCoin c t =
            c ?. M.WalletCoinTx ==. just (t ^. M.WalletTxId) &&. c ?. M.WalletCoinAddr ==.
            just (val addrI)
        joinAll t c c2 s = do
            on $ joinSpentCoin c2 s
            on $ joinSpent s t
            on $ joinCoin c t
        tables f =
            from $
            \(t `LeftOuterJoin` c `LeftOuterJoin` s `LeftOuterJoin` c2) ->
                 f t c s c2
        query t c s c2 = do
            joinAll t c c2 s
            where_
                (t ^. M.WalletTxAccount ==. val ai &&.
                 (not_ (E.isNothing (c ?. M.WalletCoinId)) ||.
                  not_ (E.isNothing (c2 ?. M.WalletCoinId))))
            let order =
                    if listReverse
                        then asc
                        else desc
            orderBy [order (t ^. M.WalletTxId)]
    cntRes <-
        select $
        tables $
        \t c s c2 -> do
            query t c s c2
            return $ countDistinct $ t ^. M.WalletTxId
    let cnt = maybe 0 unValue $ listToMaybe cntRes
    when (listOffset > 0 && listOffset >= cnt) $
        throw $ WalletException "Offset beyond end of data set"
    res <-
        select $
        distinct $
        tables $
        \t c s c2 -> do
            query t c s c2
            limitOffset listLimit listOffset
            return t
    return (map (updBals . entityVal) res, cnt)
  where
    agg =
        sum .
        mapMaybe addressInfoValue .
        filter ((== walletAddrAddress) . addressInfoAddress)
    updBals t =
        let input = agg $ M.walletTxInputs t
            output = agg $ M.walletTxOutputs t
            change = agg $ M.walletTxChange t
        in t
           { M.walletTxInValue = output + change
           , M.walletTxOutValue = input
           }

accTxsFromBlock
    :: (MonadIO m, MonadThrow m)
    => M.AccountId
    -> BlockHeight
    -> Word32 -- ^ Block count (0 for all)
    -> SqlPersistT m [M.WalletTx]
accTxsFromBlock ai bh n =
    fmap (map entityVal) $
    select $
    from $
    \t -> do
        query t
        orderBy [asc (t ^. M.WalletTxConfirmedHeight), asc (t ^. M.WalletTxId)]
        return t
  where
    query t
        | n == 0 =
            where_ $
            t ^. M.WalletTxAccount ==. val ai &&. t ^. M.WalletTxConfirmedHeight >=.
            just (val bh)
        | otherwise =
            where_ $
            t ^. M.WalletTxAccount ==. val ai &&. t ^. M.WalletTxConfirmedHeight >=.
            just (val bh) &&.
            t ^.
            M.WalletTxConfirmedHeight <.
            just (val $ bh + n)

-- Helper function to get a transaction from the wallet database. The function
-- will look across all accounts and return the first available transaction. If
-- the transaction does not exist, this function will throw a wallet exception.
getTx
    :: MonadIO m
    => TX.TxHash -> SqlPersistT m (Maybe TX.Tx)
getTx txid =
    fmap (listToMaybe . map unValue) $
    select $
    from $
    \t -> do
        where_ $ t ^. M.WalletTxHash ==. val txid
        limit 1
        return $ t ^. M.WalletTxTx

getAccountTx
    :: MonadIO m
    => M.AccountId -> TX.TxHash -> SqlPersistT m M.WalletTx
getAccountTx ai txid = do
    res <-
        select $
        from $
        \t -> do
            where_
                (t ^. M.WalletTxAccount ==. val ai &&. t ^. M.WalletTxHash ==. val txid)
            return t
    case res of
        (Entity _ tx:_) -> return tx
        _ ->
            liftIO . throwIO $
            WalletException $
            unwords ["Transaction does not exist:", cs $ TX.txHashToHex txid]

-- Helper function to get all the pending transactions from the database. It is
-- used to re-broadcast pending transactions in the wallet that have not been
-- included into blocks yet.
getPendingTxs
    :: MonadIO m
    => Int -> SqlPersistT m [TX.TxHash]
getPendingTxs i =
    fmap (map unValue) $
    select $
    from $
    \t -> do
        where_ $ t ^. M.WalletTxConfidence ==. val TxPending
        when (i > 0) $ limit $ fromIntegral i
        return $ t ^. M.WalletTxHash

{- Transaction Import -}
-- | Import a transaction into the wallet from an unknown source. If the
-- transaction is standard, valid, all inputs are known and all inputs can be
-- spent, then the transaction will be imported as a network transaction.
-- Otherwise, the transaction will be imported into the local account as an
-- offline transaction.
importTx
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => TX.Tx -- ^ Transaction to import
    -> Maybe (TBMChan Notif)
    -> M.AccountId -- ^ Account ID
    -> SqlPersistT m ([M.WalletTx], [M.WalletAddr]) -- ^ New transactions and addresses created
importTx tx notifChanM ai =
    importTx' tx notifChanM ai =<< getInCoins tx (Just ai)

importTx'
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => TX.Tx -- ^ Transaction to import
    -> Maybe (TBMChan Notif)
    -> M.AccountId -- ^ Account ID
    -> [InCoinData] -- ^ Input coins
    -> SqlPersistT m ([M.WalletTx], [M.WalletAddr])
-- ^ Transaction hash (after possible merges)
importTx' origTx notifChanM ai origInCoins
                               -- Merge the transaction with any previously existing transactions
 = do
    mergeResM <- mergeNoSigHashTxs ai origTx origInCoins
    let tx = fromMaybe origTx mergeResM
        origTxid = TX.txHash origTx
        txid = TX.txHash tx
    -- If the transaction was merged into a new transaction,
    -- update the old hashes to the new ones. This allows us to
    -- keep the spending information of our coins. It is thus possible
    -- to spend partially signed multisignature transactions (as offline
    -- transactions) even before all signatures have arrived.
    inCoins <-
        if origTxid == txid
            then return origInCoins
                 -- Update transactions
            else do
                update $
                    \t -> do
                        set t [M.WalletTxHash =. val txid, M.WalletTxTx =. val tx]
                        where_
                            (t ^. M.WalletTxAccount ==. val ai &&. t ^. M.WalletTxHash ==.
                             val origTxid)
                -- Update coins
                update $
                    \t -> do
                        set t [M.WalletCoinHash =. val txid]
                        where_
                            (t ^. M.WalletCoinAccount ==. val ai &&. t ^. M.WalletCoinHash ==.
                             val origTxid)
                let f (InCoinData c t x) =
                        if M.walletTxHash t == origTxid
                            then InCoinData
                                     c
                                     t
                                     { M.walletTxHash = txid
                                     , M.walletTxTx = tx
                                     }
                                     x
                            else InCoinData c t x
                return $ map f origInCoins
    spendingTxs <- getSpendingTxs tx (Just ai)
    let validTx = TX.verifyStdTx tx $ map toVerDat inCoins
        validIn =
            length inCoins == length (TX.txIn tx) &&
            canSpendCoins inCoins spendingTxs False
    if validIn && validTx
        then importNetTx tx notifChanM
        else importOfflineTx tx notifChanM ai inCoins spendingTxs
  where
    toVerDat (InCoinData (Entity _ c) t _) =
        (M.walletCoinScript c, TX.OutPoint (M.walletTxHash t) (M.walletCoinPos c))

-- Offline transactions are usually multisignature transactions requiring
-- additional signatures. This function will merge the signatures of
-- the same offline transactions together into one single transaction.
mergeNoSigHashTxs
    :: MonadIO m
    => M.AccountId -> TX.Tx -> [InCoinData] -> SqlPersistT m (Maybe TX.Tx)
mergeNoSigHashTxs ai tx inCoins = do
    prevM <- getBy $ M.UniqueAccNoSig ai $ TX.nosigTxHash tx
    return $
        case prevM of
            Just (Entity _ prev) ->
                case M.walletTxConfidence prev of
                    TxOffline ->
                        eitherToMaybe $ TX.mergeTxs [tx, M.walletTxTx prev] outPoints
                    _ -> Nothing
            -- Nothing to merge. Return the original transaction.
            _ -> Nothing
  where
    buildOutpoint c t = TX.OutPoint (M.walletTxHash t) (M.walletCoinPos c)
    f (InCoinData (Entity _ c) t _) = (M.walletCoinScript c, buildOutpoint c t)
    outPoints = map f inCoins

-- | Import an offline transaction into a specific account. Offline transactions
-- are imported either manually or from the wallet when building a partially
-- signed multisignature transaction. Offline transactions are only imported
-- into one specific account. They will not affect the input or output coins
-- of other accounts, including read-only accounts that may watch the same
-- addresses as this account.
--
-- We allow transactions to be imported manually by this function (unlike
-- `importNetTx` which imports only transactions coming from the network). This
-- means that it is possible to import completely crafted and invalid
-- transactions into the wallet. It is thus important to limit the scope of
-- those transactions to only the specific account in which it was imported.
--
-- This function will not broadcast these transactions to the network as we
-- have no idea if they are valid or not. Transactions are broadcast from the
-- transaction creation function and only if the transaction is complete.
importOfflineTx
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => TX.Tx
    -> Maybe (TBMChan Notif)
    -> M.AccountId
    -> [InCoinData]
    -> [Entity M.WalletTx]
    -> SqlPersistT m ([M.WalletTx], [M.WalletAddr])
importOfflineTx tx notifChanM ai inCoins spendingTxs
                                         -- Get all the new coins to be created by this transaction
 = do
    outCoins <- getNewCoins tx $ Just ai
    -- Only continue if the transaction is relevant to the account
    when (null inCoins && null outCoins) err
    -- Find the details of an existing transaction if it exists.
    prevM <- fmap (fmap entityVal) $ getBy $ M.UniqueAccTx ai txid
    -- Check if we can import the transaction
    unless (canImport $ M.walletTxConfidence <$> prevM) err
    -- Kill transactions that are spending our coins
    killTxIds notifChanM $ map entityKey spendingTxs
    -- Create all the transaction records for this account.
    -- This will spend the input coins and create the output coins
    txsRes <- buildAccTxs notifChanM tx TxOffline inCoins outCoins
    -- use the addresses (refill the gap addresses)
    newAddrs <-
        forM (nubBy sameKey $ map outCoinDataAddr outCoins) $ useAddress . entityVal
    return (txsRes, concat newAddrs)
  where
    txid = TX.txHash tx
    canImport prevConfM
              -- We can only re-import offline txs through this function.
     =
        (isNothing prevConfM || prevConfM == Just TxOffline) &&
        -- Check that all coins can be spent. We allow offline
        -- coins to be spent by this function unlike importNetTx.
        canSpendCoins inCoins spendingTxs True
    sameKey e1 e2 = entityKey e1 == entityKey e2
    err =
        liftIO . throwIO $
        WalletException "Could not import offline transaction"

-- | Import a transaction from the network into the wallet. This function
-- assumes transactions are imported in-order (parents first). It also assumes
-- that the confirmations always arrive after the transaction imports. This
-- function is idempotent.
--
-- When re-importing an existing transaction, this function will recompute
-- the inputs, outputs and transaction details for each account. A non-dead
-- transaction could be set to dead due to new inputs being double spent.
-- However, we do not allow dead transactions to be revived by reimporting them.
-- Transactions can only be revived if they make it into the main chain.
--
-- This function returns the network confidence of the imported transaction.
importNetTx
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => TX.Tx -- Network transaction to import
    -> Maybe (TBMChan Notif)
    -> SqlPersistT m ([M.WalletTx], [M.WalletAddr]) -- ^ Returns the new transactions and addresses created
importNetTx tx notifChanM
               -- Find all the coins spent by this transaction
 = do
    inCoins <- getInCoins tx Nothing
    -- Get all the new coins to be created by this transaction
    outCoins <- getNewCoins tx Nothing
    -- Only continue if the transaction is relevant to the wallet
    if null inCoins && null outCoins
        then return ([], [])
             -- Update incomplete offline transactions when the completed
             -- transaction comes in from the network.
        else do
            updateNosigHash tx (TX.nosigTxHash tx) txid
            -- Get the transaction spending our coins
            spendingTxs <- getSpendingTxs tx Nothing
            -- Compute the confidence
            let confidence
                    | canSpendCoins inCoins spendingTxs False = TxPending
                    | otherwise = TxDead
            -- Kill transactions that are spending our coins if we are not dead
            when (confidence /= TxDead) $ killTxIds notifChanM $ map entityKey spendingTxs
            -- Create all the transaction records for this account.
            -- This will spend the input coins and create the output coins
            txRes <- buildAccTxs notifChanM tx confidence inCoins outCoins
            -- Use up the addresses of our new coins (replenish gap addresses)
            newAddrs <-
                forM (nubBy sameKey $ map outCoinDataAddr outCoins) $
                useAddress . entityVal
            forM_ notifChanM $
                \notifChan ->
                     forM_ txRes $
                     \tx' -> do
                         let ai = M.walletTxAccount tx'
                         M.Account {..} <-
                             fromMaybe (error "Velociraptors ate you") <$> get ai
                         liftIO $
                             atomically $
                             writeTBMChan notifChan $
                             NotifTx $ M.toJsonTx accountName Nothing tx'
            return (txRes, concat newAddrs)
  where
    sameKey e1 e2 = entityKey e1 == entityKey e2
    txid = TX.txHash tx

updateNosigHash
    :: MonadIO m
    => TX.Tx -> TX.TxHash -> TX.TxHash -> SqlPersistT m ()
updateNosigHash tx nosig txid = do
    res <-
        select $
        from $
        \t -> do
            where_
                (t ^. M.WalletTxNosigHash ==. val nosig &&. t ^. M.WalletTxHash !=.
                 val txid)
            return $ t ^. M.WalletTxHash
    let toUpdate = map unValue res
    unless (null toUpdate) $
        do splitUpdate toUpdate $
               \hs t -> do
                   set t [M.WalletTxHash =. val txid, M.WalletTxTx =. val tx]
                   where_ $ t ^. M.WalletTxHash `in_` valList hs
           splitUpdate toUpdate $
               \hs c -> do
                   set c [M.WalletCoinHash =. val txid]
                   where_ $ c ^. M.WalletCoinHash `in_` valList hs

-- Check if the given coins can be spent.
canSpendCoins
    :: [InCoinData]
    -> [Entity M.WalletTx]
    -> Bool -- True for offline transactions
    -> Bool
canSpendCoins inCoins spendingTxs offline =
    all validCoin inCoins && all validSpend spendingTxs
  where
    validCoin (InCoinData _ t _)
        | offline = M.walletTxConfidence t /= TxDead
        | otherwise = M.walletTxConfidence t `elem` [TxPending, TxBuilding]
    -- All transactions spending the same coins as us should be offline
    validSpend = (== TxOffline) . M.walletTxConfidence . entityVal

-- We can only spend pending and building coins
-- Get the coins in the wallet related to the inputs of a transaction. You
-- can optionally provide an account to limit the returned coins to that
-- account only.
getInCoins
    :: MonadIO m
    => TX.Tx -> Maybe M.AccountId -> SqlPersistT m [InCoinData]
getInCoins tx aiM = do
    res <-
        splitSelect ops $
        \os ->
             from $
             \(c `InnerJoin` t `InnerJoin` x) -> do
                 on $ x ^. M.WalletAddrId ==. c ^. M.WalletCoinAddr
                 on $ t ^. M.WalletTxId ==. c ^. M.WalletCoinTx
                 where_ $
                     case aiM of
                         Just ai ->
                             c ^. M.WalletCoinAccount ==. val ai &&.
                             limitOutPoints c os
                         _ -> limitOutPoints c os
                 return (c, t, x)
    return $ map (\(c, t, x) -> InCoinData c (entityVal t) (entityVal x)) res
  where
    ops = map TX.prevOutput $ TX.txIn tx
    limitOutPoints c os = join2 $ map (f c) os
    f c (TX.OutPoint h i) =
        c ^. M.WalletCoinHash ==. val h &&. c ^. M.WalletCoinPos ==. val i

-- Find all the transactions that are spending the same coins as the given
-- transaction. You can optionally provide an account to limit the returned
-- transactions to that account only.
getSpendingTxs
    :: MonadIO m
    => TX.Tx -> Maybe M.AccountId -> SqlPersistT m [Entity M.WalletTx]
getSpendingTxs tx aiM
    | null txInputs = return []
    | otherwise =
        splitSelect txInputs $
        \ins ->
             from $
             \(s `InnerJoin` t) -> do
                 on $ s ^. M.SpentCoinSpendingTx ==. t ^. M.WalletTxId
                 -- Filter out the given transaction
                 let cond = t ^. M.WalletTxHash !=. val txid &&. limitSpent s ins
                 where_ $
                     case aiM of
                         Just ai -> cond &&. s ^. M.SpentCoinAccount ==. val ai
                         _       -> cond
                 return t
  where
    txid = TX.txHash tx
    txInputs = map TX.prevOutput $ TX.txIn tx
    limitSpent s ins = join2 $ map (f s) ins
    f s (TX.OutPoint h i) =
        s ^. M.SpentCoinHash ==. val h &&. s ^. M.SpentCoinPos ==. val i

-- Returns all the new coins that need to be created from a transaction.
-- Also returns the addresses associted with those coins.
getNewCoins
    :: MonadIO m
    => TX.Tx -> Maybe M.AccountId -> SqlPersistT m [OutCoinData]
getNewCoins tx aiM
               -- Find all the addresses which are in the transaction outputs
 = do
    addrs <-
        splitSelect uniqueAddrs $
        \as ->
             from $
             \x -> do
                 let cond = x ^. M.WalletAddrAddress `in_` valList as
                 where_ $
                     case aiM of
                         Just ai -> cond &&. x ^. M.WalletAddrAccount ==. val ai
                         _       -> cond
                 return x
    return $ concatMap toCoins addrs
  where
    uniqueAddrs = nub $ map (\(addr, _, _, _) -> addr) outList
    outList = rights $ map toDat txOutputs
    txOutputs = zip (TX.txOut tx) [0 ..]
    toDat (out, pos) =
        getDataFromOutput out >>= \(addr, so) -> return (addr, out, pos, so)
    toCoins addrEnt@(Entity _ addr) =
        let f (a, _, _, _) = a == M.walletAddrAddress addr
        in map (toCoin addrEnt) $ filter f outList
    toCoin addrEnt (_, out, pos, so) =
        OutCoinData
        { outCoinDataAddr = addrEnt
        , outCoinDataPos = pos
        , outCoinDataValue = TX.outValue out
        , outCoinDataScript = so
        }

-- Decode an output and extract an output script and a recipient address
getDataFromOutput :: TX.TxOut -> Either String (CY.Address, ScriptOutput)
getDataFromOutput out = do
    so <- decodeOutputBS $ TX.scriptOutput out
    addr <- outputAddress so
    return (addr, so)

isCoinbaseTx :: TX.Tx -> Bool
isCoinbaseTx tx =
    length (TX.txIn tx) == 1 &&
    TX.outPointHash (TX.prevOutput $ head (TX.txIn tx)) ==
    "0000000000000000000000000000000000000000000000000000000000000000"

-- | Spend the given input coins. We also create dummy coins for the inputs
-- in a transaction that do not belong to us. This is to be able to detect
-- double spends when reorgs occur.
spendInputs
    :: MonadIO m
    => M.AccountId -> M.WalletTxId -> TX.Tx -> SqlPersistT m ()
spendInputs ai ti tx = do
    now <- liftIO getCurrentTime
    -- Spend the coins by inserting values in SpentCoin
    splitInsertMany_ $ map (buildSpentCoin now) txInputs
  where
    txInputs = map TX.prevOutput $ TX.txIn tx
    buildSpentCoin now (TX.OutPoint h p) =
        M.SpentCoin
        { spentCoinAccount = ai
        , spentCoinHash = h
        , spentCoinPos = p
        , spentCoinSpendingTx = ti
        , spentCoinCreated = now
        }

-- Build account transaction for the given input and output coins
buildAccTxs
    :: MonadIO m
    => Maybe (TBMChan Notif)
    -> TX.Tx
    -> TxConfidence
    -> [InCoinData]
    -> [OutCoinData]
    -> SqlPersistT m [M.WalletTx]
buildAccTxs notifChanM tx confidence inCoins outCoins = do
    now <- liftIO getCurrentTime
    -- Group the coins by account
    let grouped = groupCoinsByAccount inCoins outCoins
    forM (M.toList grouped) $
        \(ai, (is, os)) -> do
            let atx = buildAccTx tx confidence ai is os now
            -- Insert the new transaction. If it already exists, update the
            -- information with the newly computed values. Also make sure that the
            -- confidence is set to the new value (it could have changed to TxDead).
            Entity ti newAtx <-
                P.insertBy atx >>=
                \resE ->
                     case resE of
                         Left (Entity ti prev) -> do
                             let prevConf = M.walletTxConfidence prev
                                 newConf
                                     | confidence == TxDead = TxDead
                                     | prevConf == TxBuilding = TxBuilding
                                     | otherwise = confidence
                             -- If the transaction already exists, preserve confirmation data
                             let newAtx =
                                     atx
                                     { M.walletTxConfidence = newConf
                                     , M.walletTxConfirmedBy =
                                         M.walletTxConfirmedBy prev
                                     , M.walletTxConfirmedHeight =
                                         M.walletTxConfirmedHeight prev
                                     , M.walletTxConfirmedDate =
                                         M.walletTxConfirmedDate prev
                                     }
                             replace ti newAtx
                             -- Spend inputs only if the previous transaction was dead
                             when (newConf /= TxDead && prevConf == TxDead) $
                                 spendInputs ai ti tx
                             -- If the transaction changed from non-dead to dead, kill it.
                             -- This will remove spent coins and child transactions.
                             when (prevConf /= TxDead && newConf == TxDead) $
                                 killTxIds notifChanM [ti]
                             return (Entity ti newAtx)
                         Right ti -> do
                             when (confidence /= TxDead) $ spendInputs ai ti tx
                             return (Entity ti atx)
            -- Insert the output coins with updated accTx key
            let newOs = map (toCoin ai ti now) os
            forM_ newOs $
                \c ->
                     P.insertBy c >>=
                     \resE ->
                          case resE of
                              Left (Entity ci _) -> replace ci c
                              _                  -> return ()
            -- Return the new transaction record
            return newAtx
  where
    toCoin ai accTxId now (OutCoinData addrEnt pos vl so) =
        M.WalletCoin
        { walletCoinAccount = ai
        , walletCoinHash = TX.txHash tx
        , walletCoinPos = pos
        , walletCoinTx = accTxId
        , walletCoinValue = vl
        , walletCoinScript = so
        , walletCoinAddr = entityKey addrEnt
        , walletCoinCreated = now
        }

-- | Build an account transaction given the input and output coins relevant to
-- this specific account. An account transaction contains the details of how a
-- transaction affects one particular account (value sent to and from the
-- account). The first value is Maybe an existing transaction in the database
-- which is used to get the existing confirmation values.
buildAccTx :: TX.Tx
           -> TxConfidence
           -> M.AccountId
           -> [InCoinData]
           -> [OutCoinData]
           -> UTCTime
           -> M.WalletTx
buildAccTx tx confidence ai inCoins outCoins now =
    M.WalletTx
    { walletTxAccount = ai
    , walletTxHash = TX.txHash tx
    -- This is a hash of the transaction excluding signatures. This allows us
    -- to track the evolution of offline transactions as we add more signatures
    -- to them.
    , walletTxNosigHash = TX.nosigTxHash tx
    , walletTxType = txType
    , walletTxInValue = inVal
    , walletTxOutValue = outVal
    , walletTxInputs =
        let f h i (InCoinData (Entity _ c) t _) =
                M.walletTxHash t == h && M.walletCoinPos c == i
            toInfo (a, TX.OutPoint h i) =
                case find (f h i) inCoins of
                    Just (InCoinData (Entity _ c) _ _) ->
                        AddressInfo a (Just $ M.walletCoinValue c) True
                    _ -> AddressInfo a Nothing False
        in map toInfo allInAddrs
    , walletTxOutputs =
        let toInfo (a, i, v) = AddressInfo a (Just v) $ ours i
            ours i = isJust $ find ((== i) . outCoinDataPos) outCoins
        in map toInfo allOutAddrs \\ changeAddrs
    , walletTxChange = changeAddrs
    , walletTxTx = tx
    , walletTxIsCoinbase = isCoinbaseTx tx
    , walletTxConfidence = confidence
    -- Reuse the confirmation information of the existing transaction if
    -- we have it.
    , walletTxConfirmedBy = Nothing
    , walletTxConfirmedHeight = Nothing
    , walletTxConfirmedDate = Nothing
    , walletTxCreated = now
    }
  where
    inVal = sum $ map outCoinDataValue outCoins
    -- The value going out of the account is the sum on the input coins
    outVal = sum $ map TX.coinValue inCoins
    allMyCoins =
        length inCoins == length (TX.txIn tx) &&
        length outCoins == length (TX.txOut tx)
    txType
    -- If all the coins belong to the same account, it is a self
    -- transaction (even if a fee was payed).
        | allMyCoins = TxSelf
        -- This case can happen in complex transactions where the total
        -- input/output sum for a given account is 0. In this case, we count
        -- that transaction as a TxSelf. This should not happen with simple
        -- transactions.
        | inVal == outVal = TxSelf
        | inVal > outVal = TxIncoming
        | otherwise = TxOutgoing
    -- List of all the decodable input addresses in the transaction
    allInAddrs =
        let f inp = do
                input <- decodeInputBS (TX.scriptInput inp)
                addr <- inputAddress input
                return (addr, TX.prevOutput inp)
        in rights $ map f $ TX.txIn tx
    -- List of all the decodable output addresses in the transaction
    allOutAddrs =
        let f op i = do
                addr <- outputAddress =<< decodeOutputBS (TX.scriptOutput op)
                return (addr, i, TX.outValue op)
        in rights $ zipWith f (TX.txOut tx) [0 ..]
    changeAddrs
        | txType == TxIncoming = []
        | otherwise =
            let isInternal =
                    (== AddressInternal) . M.walletAddrType . entityVal . outCoinDataAddr
                f = M.walletAddrAddress . entityVal . outCoinDataAddr
                toInfo c = AddressInfo (f c) (Just $ outCoinDataValue c) True
            in map toInfo $ filter isInternal outCoins

-- The value going into the account is the sum of the output coins
-- Group all the input and outputs coins from the same account together.
groupCoinsByAccount :: [InCoinData]
                    -> [OutCoinData]
                    -> M.Map M.AccountId ([InCoinData], [OutCoinData])
groupCoinsByAccount inCoins outCoins = M.unionWith merge inMap outMap
  where
    f coin@(InCoinData _ t _) = (M.walletTxAccount t, [coin])
    g coin = (M.walletAddrAccount $ entityVal $ outCoinDataAddr coin, [coin])
    merge (is, _) (_, os) = (is, os)
    inMap = M.map (\is -> (is, [])) $ M.fromListWith (++) $ map f inCoins
    outMap = M.map (\os -> ([], os)) $ M.fromListWith (++) $ map g outCoins

-- Build a map from accounts -> (inCoins, outCoins)
deleteTx
    :: (MonadIO m, MonadThrow m)
    => TX.TxHash -> SqlPersistT m ()
deleteTx txid = do
    ts <-
        select $
        from $
        \t -> do
            where_ $ t ^. M.WalletTxHash ==. val txid
            return t
    case ts of
        [] ->
            throwM $
            WalletException $
            unwords
                ["Cannot delete inexistent transaction", cs (TX.txHashToHex txid)]
        Entity {entityVal = M.WalletTx {walletTxConfidence = TxBuilding}}:_ ->
            throwM $
            WalletException $
            unwords
                ["Cannot delete confirmed transaction", cs (TX.txHashToHex txid)]
        _ -> return ()
    children <-
        fmap (map unValue) $
        select $
        from $
        \(t `InnerJoin` c `InnerJoin` s `InnerJoin` t2) -> do
            on $ s ^. M.SpentCoinSpendingTx ==. t2 ^. M.WalletTxId
            on
                (c ^. M.WalletCoinAccount ==. t ^. M.WalletTxAccount &&. c ^. M.WalletCoinHash ==.
                 s ^.
                 M.SpentCoinHash &&.
                 c ^.
                 M.WalletCoinPos ==.
                 s ^.
                 M.SpentCoinPos)
            on $ c ^. M.WalletCoinTx ==. t ^. M.WalletTxId
            where_ $ t ^. M.WalletTxHash ==. val txid
            return $ t2 ^. M.WalletTxHash
    forM_ children deleteTx
    forM_ ts $
        \Entity {entityKey = ti} ->
             delete $ from $ \s -> where_ $ s ^. M.SpentCoinSpendingTx ==. val ti
    delete $ from $ \s -> where_ $ s ^. M.SpentCoinHash ==. val txid
    forM_ ts $
        \Entity {entityKey = ti} -> do
            delete $ from $ \c -> where_ $ c ^. M.WalletCoinTx ==. val ti
            delete $ from $ \t -> where_ $ t ^. M.WalletTxId ==. val ti

-- Kill transactions and their children by ids.
killTxIds
    :: MonadIO m
    => Maybe (TBMChan Notif) -> [M.WalletTxId] -> SqlPersistT m ()
killTxIds notifChanM txIds
                     -- Find all the transactions spending the coins of these transactions
                     -- (Find all the child transactions)
 = do
    children <-
        splitSelect txIds $
        \ts ->
             from $
             \(t `InnerJoin` s) -> do
                 on
                     (s ^. M.SpentCoinAccount ==. t ^. M.WalletTxAccount &&. s ^. M.SpentCoinHash ==.
                      t ^.
                      M.WalletTxHash)
                 where_ $ t ^. M.WalletTxId `in_` valList ts
                 return $ s ^. M.SpentCoinSpendingTx
    -- Kill these transactions
    splitUpdate txIds $
        \ts t -> do
            set t [M.WalletTxConfidence =. val TxDead]
            where_ $ t ^. M.WalletTxId `in_` valList ts
    case notifChanM of
        Nothing -> return ()
        Just notifChan -> do
            ts' <-
                fmap (map entityVal) $
                splitSelect txIds $
                \ts ->
                     from $
                     \t -> do
                         where_ $ t ^. M.WalletTxId `in_` valList ts
                         return t
            forM_ ts' $
                \tx -> do
                    let ai = M.walletTxAccount tx
                    M.Account {..} <-
                        fromMaybe (error "More velociraptors coming") <$> get ai
                    liftIO $
                        atomically $
                        writeTBMChan notifChan $
                        NotifTx $ M.toJsonTx accountName Nothing tx
    -- This transaction doesn't spend any coins
    splitDelete txIds $
        \ts -> from $ \s -> where_ $ s ^. M.SpentCoinSpendingTx `in_` valList ts
    -- Recursively kill all the child transactions.
    -- (Recurse at the end in case there are closed loops)
    unless (null children) $ killTxIds notifChanM $ nub $ map unValue children

-- Kill transactions and their child transactions by hashes.
killTxs
    :: MonadIO m
    => Maybe (TBMChan Notif) -> [TX.TxHash] -> SqlPersistT m ()
killTxs notifChanM txHashes = do
    res <-
        splitSelect txHashes $
        \hs ->
             from $
             \t -> do
                 where_ $ t ^. M.WalletTxHash `in_` valList hs
                 return $ t ^. M.WalletTxId
    killTxIds notifChanM $ map unValue res

{- Confirmations -}
importMerkles
    :: MonadIO m
    => BlockChainAction
    -> [MerkleTxs]
    -> Maybe (TBMChan Notif)
    -> SqlPersistT m ()
importMerkles action expTxsLs notifChanM =
    when (isBestChain action || isChainReorg action) $
    do case action of
           ChainReorg _ os _
           -- Unconfirm transactions from the old chain.
            ->
               let hs = map (Just . nodeHash) os
               in splitUpdate hs $
                  \h t -> do
                      set
                          t
                          [ M.WalletTxConfidence =. val TxPending
                          , M.WalletTxConfirmedBy =. val Nothing
                          , M.WalletTxConfirmedHeight =. val Nothing
                          , M.WalletTxConfirmedDate =. val Nothing
                          ]
                      where_ $ t ^. M.WalletTxConfirmedBy `in_` valList h
           _ -> return ()
       -- Find all the dead transactions which need to be revived
       deadTxs <-
           splitSelect (concat expTxsLs) $
           \ts ->
                from $
                \t -> do
                    where_
                        (t ^. M.WalletTxHash `in_` valList ts &&. t ^. M.WalletTxConfidence ==.
                         val TxDead)
                    return $ t ^. M.WalletTxTx
       -- Revive dead transactions (in no particular order)
       forM_ deadTxs $ reviveTx notifChanM . unValue
       -- Confirm the transactions
       forM_ (zip (actionNodes action) expTxsLs) $
           \(node, hs) -> do
               let hash = nodeHash node
                   height = nodeBlockHeight node
               splitUpdate hs $
                   \h t -> do
                       set
                           t
                           [ M.WalletTxConfidence =. val TxBuilding
                           , M.WalletTxConfirmedBy =. val (Just hash)
                           , M.WalletTxConfirmedHeight =. val (Just height)
                           , M.WalletTxConfirmedDate =.
                             val (Just $ nodeTimestamp node)
                           ]
                       where_ $ t ^. M.WalletTxHash `in_` valList h
               ts <-
                   fmap (map entityVal) $
                   splitSelect hs $
                   \h ->
                        from $
                        \t -> do
                            where_ $ t ^. M.WalletTxHash `in_` valList h
                            return t
               -- Update the best height in the wallet (used to compute the number
               -- of confirmations of transactions)
               setBestBlock hash height
               -- Send notification for block
               forM_ notifChanM $
                   \notifChan -> do
                       liftIO $
                           atomically $
                           writeTBMChan notifChan $
                           NotifBlock
                               JsonBlock
                               { jsonBlockHash = hash
                               , jsonBlockHeight = height
                               , jsonBlockPrev = nodePrev node
                               }
                       sendTxs notifChan ts hash height
  where
    sendTxs notifChan ts hash height =
        forM_ ts $
        \tx -> do
            let ai = M.walletTxAccount tx
            M.Account {..} <- fromMaybe (error "Dino crisis") <$> get ai
            liftIO $
                atomically $
                writeTBMChan notifChan $
                NotifTx $ M.toJsonTx accountName (Just (hash, height)) tx

-- Helper function to set the best block and best block height in the DB.
setBestBlock
    :: MonadIO m
    => BlockHash -> Word32 -> SqlPersistT m ()
setBestBlock bid i =
    update $
    \t -> set t [M.WalletStateBlock =. val bid, M.WalletStateHeight =. val i]

-- Helper function to get the best block and best block height from the DB
walletBestBlock
    :: MonadIO m
    => SqlPersistT m (BlockHash, Word32)
walletBestBlock = do
    cfgM <- fmap entityVal <$> P.selectFirst [] []
    return $
        case cfgM of
            Just M.WalletState {..} -> (walletStateBlock, walletStateHeight)
            Nothing ->
                throw $
                WalletException $
                unwords
                    [ "Could not get the best block."
                    , "Wallet database is probably not initialized"
                    ]

-- Revive a dead transaction. All transactions that are in conflict with this
-- one will be killed.
reviveTx
    :: MonadIO m
    => Maybe (TBMChan Notif) -> TX.Tx -> SqlPersistT m ()
reviveTx notifChanM tx
                    -- Kill all transactions spending our coins
 = do
    spendingTxs <- getSpendingTxs tx Nothing
    killTxIds notifChanM $ map entityKey spendingTxs
    -- Find all the WalletTxId that have to be revived
    ids <-
        select $
        from $
        \t -> do
            where_ $
                t ^. M.WalletTxHash ==. val (TX.txHash tx) &&. t ^. M.WalletTxConfidence ==.
                val TxDead
            return (t ^. M.WalletTxAccount, t ^. M.WalletTxId)
    -- Spend the inputs for all our transactions
    forM_ ids $ \(Value ai, Value ti) -> spendInputs ai ti tx
    let ids' = map (unValue . snd) ids
    -- Update the transactions
    splitUpdate ids' $
        \is t -> do
            set
                t
                [ M.WalletTxConfidence =. val TxPending
                , M.WalletTxConfirmedBy =. val Nothing
                , M.WalletTxConfirmedHeight =. val Nothing
                , M.WalletTxConfirmedDate =. val Nothing
                ]
            where_ $ t ^. M.WalletTxId `in_` valList is
    case notifChanM of
        Nothing -> return ()
        Just notifChan -> do
            ts' <-
                fmap (map entityVal) $
                splitSelect ids' $
                \ts ->
                     from $
                     \t -> do
                         where_ $ t ^. M.WalletTxId `in_` valList ts
                         return t
            forM_ ts' $
                \tx' -> do
                    let ai = M.walletTxAccount tx'
                    M.Account {..} <-
                        fromMaybe (error "Tyranossaurus Rex attacks") <$> get ai
                    liftIO $
                        atomically $
                        writeTBMChan notifChan $
                        NotifTx $ M.toJsonTx accountName Nothing tx'

{- Transaction creation and signing (local wallet functions) -}
-- | Create a transaction sending some coins to a list of recipient addresses.
createWalletTx
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => Entity M.Account -- ^ Account Entity
    -> Maybe (TBMChan Notif) -- ^ Notification channel
    -> Maybe CY.XPrvKey -- ^ Key if not provided by account
    -> [(CY.Address, Word64)] -- ^ List of recipient addresses and amounts
    -> Word64 -- ^ Fee per 1000 bytes
    -> Word32 -- ^ Minimum confirmations
    -> Bool -- ^ Should fee be paid by recipient
    -> Bool -- ^ Should the transaction be signed
    -> SqlPersistT m (M.WalletTx, [M.WalletAddr]) -- ^ (New transaction hash, Completed flag)
createWalletTx accE@(Entity ai acc) notifM masterM dests fee minConf rcptFee sign
                                                                             -- Build an unsigned transaction from the given recipient values and fee
 = do
    (unsignedTx, inCoins, newChangeAddrs) <-
        buildUnsignedTx accE dests fee minConf rcptFee
    -- Sign our new transaction if signing was requested
    let dat = map toCoinSignData inCoins
        tx
            | sign = signOfflineTx acc masterM unsignedTx dat
            | otherwise = unsignedTx
    -- Import the transaction in the wallet either as a network transaction if
    -- it is complete, or as an offline transaction otherwise.
    (res, newAddrs) <- importTx' tx notifM ai inCoins
    case res of
        (txRes:_) -> return (txRes, newAddrs ++ newChangeAddrs)
        _ ->
            liftIO . throwIO $
            WalletException "Error while importing the new transaction"

toCoinSignData :: InCoinData -> CoinSignData
toCoinSignData (InCoinData (Entity _ c) t x) =
    CoinSignData
        (TX.OutPoint (M.walletTxHash t) (M.walletCoinPos c))
        (M.walletCoinScript c)
        deriv
  where
    deriv = CY.Deriv
            CY.:/ addrTypeIndex (M.walletAddrType x)
            CY.:/ M.walletAddrIndex x

-- Build an unsigned transaction given a list of recipients and a fee. Returns
-- the unsigned transaction together with the input coins that have been
-- selected or spending.
buildUnsignedTx
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => Entity M.Account
    -> [(CY.Address, Word64)]
    -> Word64
    -> Word32
    -> Bool
    -> SqlPersistT m (TX.Tx, [InCoinData], [M.WalletAddr]) -- ^ Generated change addresses
buildUnsignedTx _ [] _ _ _ =
    liftIO . throwIO $
    WalletException
        "buildUnsignedTx: No transaction recipients have been provided"
buildUnsignedTx accE@(Entity ai acc) origDests origFee minConf rcptFee = do
    let p =
            case M.accountType acc of
                AccountMultisig m n -> (m, n)
                _                   -> throw . WalletException $ "Invalid account type"
        fee =
            if rcptFee
                then 0
                else origFee
        coins
            | isMultisigAccount acc = TX.chooseMSCoins tot fee p True
            | otherwise = TX.chooseCoins tot fee True
        -- TODO: Add more policies like confirmations or coin age
        -- Sort coins by their values in descending order
        orderPolicy c _ = [desc $ c ^. M.WalletCoinValue]
    -- Find the spendable coins in the given account with the required number
    -- of minimum confirmations.
    selectRes <- spendableCoins ai minConf orderPolicy
    -- Find a selection of spendable coins that matches our target value
    let (selected, change) = either (throw . WalletException) id $ coins selectRes
        totFee
            | isMultisigAccount acc = TX.getMSFee origFee p (length selected)
            | otherwise = TX.getFee origFee (length selected)
        -- Subtract fees from first destination if rcptFee
        value = snd $ head origDests
    -- First output must not be dust after deducting fees
    when (rcptFee && value < totFee + 5430) $
        throw $ WalletException "First recipient cannot cover transaction fees"
    -- Subtract fees from first destination if rcptFee
    let dests
            | rcptFee =
                second (const $ value - totFee) (head origDests) : tail origDests
            | otherwise = origDests
    -- Make sure the first recipient has enough funds to cover the fee
    when (snd (head dests) <= 0) $
        throw $ WalletException "Transaction fees too high"
    -- If the change amount is not dust, we need to add a change address to
    -- our list of recipients.
    -- TODO: Put the dust value in a constant somewhere. We also need a more
    -- general way of detecting dust such as our transactions are not
    -- rejected by full nodes.
    (allDests, addrs) <-
        if change < 5430
            then return (dests, [])
            else do
                (addr, chng) <- newChangeAddr change
                return ((M.walletAddrAddress addr, chng) : dests, [addr])
    case TX.buildAddrTx (map toOutPoint selected) $ map toBase58 allDests of
        Right tx -> return (tx, selected, addrs)
        Left err -> liftIO . throwIO $ WalletException err
  where
    tot = sum $ map snd origDests
    toBase58 (a, v) = (CY.addrToBase58 a, v)
    toOutPoint (InCoinData (Entity _ c) t _) =
        TX.OutPoint (M.walletTxHash t) (M.walletCoinPos c)
    newChangeAddr change = do
        let lq = ListRequest 0 0 False
        (as, _) <- unusedAddresses accE AddressInternal lq
        case as of
            (a:_)
            -- Use the address to prevent reusing it again
             -> do
                _ <- useAddress a
                -- TODO: Randomize the change position
                return (a, change)
            _ ->
                liftIO . throwIO $
                WalletException "No unused addresses available"

signAccountTx
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => Entity M.Account
    -> Maybe (TBMChan Notif)
    -> Maybe CY.XPrvKey
    -> TX.TxHash
    -> SqlPersistT m ([M.WalletTx], [M.WalletAddr])
signAccountTx (Entity ai acc) notifChanM masterM txid = do
    (OfflineTxData tx dat, inCoins) <- getOfflineTxData ai txid
    let signedTx = signOfflineTx acc masterM tx dat
    importTx' signedTx notifChanM ai inCoins

getOfflineTxData
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => M.AccountId -> TX.TxHash -> SqlPersistT m (OfflineTxData, [InCoinData])
getOfflineTxData ai txid = do
    txM <- getBy $ M.UniqueAccTx ai txid
    case txM of
        Just (Entity _ tx) -> do
            unless (M.walletTxConfidence tx == TxOffline) $
                liftIO . throwIO $
                WalletException "Can only sign offline transactions."
            inCoins <- getInCoins (M.walletTxTx tx) $ Just ai
            return
                (OfflineTxData (M.walletTxTx tx) $ map toCoinSignData inCoins, inCoins)
        _ ->
            liftIO . throwIO $
            WalletException $ unwords ["Invalid txid", cs $ TX.txHashToHex txid]

-- Sign a transaction using a list of CoinSignData. This allows an offline
-- signer without access to the coins to sign a given transaction.
signOfflineTx
    :: M.Account -- ^ Account used for signing
    -> Maybe CY.XPrvKey -- ^ Key if not provided in account
    -> TX.Tx -- ^ Transaction to sign
    -> [CoinSignData] -- ^ Input signing data
    -> TX.Tx
signOfflineTx acc masterM tx coinSignData
    | not validMaster = throw $ WalletException "Master key not valid"
    -- Sign the transaction deterministically
    | otherwise =
        either (throw . WalletException) id $
        TX.signTx tx sigData $ map (CY.toPrvKeyG . CY.xPrvKey) prvKeys
  where
    sigData = map (toSigData acc) coinSignData
    -- Compute all the private keys
    prvKeys = map toPrvKey coinSignData
    -- Build a SigInput from a CoinSignData
    toSigData acc' (CoinSignData op so deriv)
                   -- TODO: Here we override the SigHash to be SigAll False all the time.
                   -- Should we be more flexible?
     =
        TX.SigInput so op (SigAll False) $
        if isMultisigAccount acc
            then Just $ getPathRedeem acc' deriv
            else Nothing
    toPrvKey (CoinSignData _ _ deriv) = CY.derivePath deriv master
    master =
        case masterM of
            Just m ->
                case M.accountDerivation acc of
                    Just d  -> CY.derivePath d m
                    Nothing -> m
            Nothing ->
                fromMaybe
                    (throw $ WalletException "No extended private key available")
                    (M.accountMaster acc)
    validMaster = CY.deriveXPubKey master `elem` M.accountKeys acc

-- Compute all the SigInputs
-- Returns unspent coins that can be spent in an account that have a minimum
-- number of confirmations. Coinbase coins can only be spent after 100
-- confirmations.
spendableCoins
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => M.AccountId -- ^ Account key
    -> Word32 -- ^ Minimum confirmations
    -> (SqlExpr (Entity M.WalletCoin) -> SqlExpr (Entity M.WalletTx) -> [SqlExpr OrderBy])
       -- ^ Coin ordering policy
    -> SqlPersistT m [InCoinData] -- ^ Spendable coins
spendableCoins ai minConf orderPolicy =
    fmap (map f) $ select $ spendableCoinsFrom ai minConf orderPolicy
  where
    f (c, t, x) = InCoinData c (entityVal t) (entityVal x)

spendableCoinsFrom
    :: M.AccountId -- ^ Account key
    -> Word32 -- ^ Minimum confirmations
    -> (SqlExpr (Entity M.WalletCoin) -> SqlExpr (Entity M.WalletTx) -> [SqlExpr OrderBy])
       -- ^ Coin ordering policy
    -> SqlQuery (SqlExpr (Entity M.WalletCoin), SqlExpr (Entity M.WalletTx), SqlExpr (Entity M.WalletAddr))
spendableCoinsFrom ai minConf orderPolicy =
    from $
    \(c `InnerJoin` t `InnerJoin` x `LeftOuterJoin` s)
    -- Joins have to be set in reverse order !
    -- Left outer join on spent coins
     -> do
        on
            (s ?. M.SpentCoinAccount ==. just (c ^. M.WalletCoinAccount) &&. s ?. M.SpentCoinHash ==.
             just (c ^. M.WalletCoinHash) &&.
             s ?.
             M.SpentCoinPos ==.
             just (c ^. M.WalletCoinPos))
        on $ x ^. M.WalletAddrId ==. c ^. M.WalletCoinAddr
        -- Inner join on coins and transactions
        on $ t ^. M.WalletTxId ==. c ^. M.WalletCoinTx
        where_
            (c ^. M.WalletCoinAccount ==. val ai &&. t ^. M.WalletTxConfidence `in_`
             valList [TxPending, TxBuilding] &&.
             E.isNothing (s ?. M.SpentCoinId) &&.
             limitConfirmations (Right t) minConf)
        orderBy (orderPolicy c t)
        return (c, t, x)

-- If the current height is 200 and a coin was confirmed at height 198, then it
-- has 3 confirmations. So, if we require 3 confirmations, we want coins with a
-- confirmed height of 198 or less (200 - 3 + 1).
limitConfirmations
    :: Either (SqlExpr (Maybe (Entity M.WalletTx))) (SqlExpr (Entity M.WalletTx))
    -> Word32
    -> SqlExpr (Value Bool)
limitConfirmations txE minconf
    | minconf == 0 = limitCoinbase
    | minconf < 100 = limitConfs minconf &&. limitCoinbase
    | otherwise = limitConfs minconf
  where
    limitConfs i =
        case txE of
            Left t ->
                t ?. M.WalletTxConfirmedHeight <=.
                just (just (selectHeight -. val (i - 1)))
            Right t ->
                t ^. M.WalletTxConfirmedHeight <=.
                just (selectHeight -. val (i - 1))
    -- Coinbase transactions require 100 confirmations
    limitCoinbase =
        case txE of
            Left t ->
                not_ (coalesceDefault [t ?. M.WalletTxIsCoinbase] (val False)) ||.
                limitConfs 100
            Right t -> not_ (t ^. M.WalletTxIsCoinbase) ||. limitConfs 100
    selectHeight :: SqlExpr (Value Word32)
    selectHeight =
        sub_select $
        from $
        \co -> do
            limit 1
            return $ co ^. M.WalletStateHeight

{- Balances -}
accountBalance
    :: MonadIO m
    => M.AccountId -> Word32 -> Bool -> SqlPersistT m Word64
accountBalance ai minconf offline = do
    res <-
        select $
        from $
        \(c `InnerJoin` t `LeftOuterJoin` s `LeftOuterJoin` st) -> do
            on $ st ?. M.WalletTxId ==. s ?. M.SpentCoinSpendingTx
            on
                (s ?. M.SpentCoinAccount ==. just (c ^. M.WalletCoinAccount) &&. s ?.
                 M.SpentCoinHash ==.
                 just (c ^. M.WalletCoinHash) &&.
                 s ?.
                 M.SpentCoinPos ==.
                 just (c ^. M.WalletCoinPos))
            on $ t ^. M.WalletTxId ==. c ^. M.WalletCoinTx
            let unspent = E.isNothing (s ?. M.SpentCoinId)
                spentOffline = st ?. M.WalletTxConfidence ==. just (val TxOffline)
                cond =
                    c ^. M.WalletCoinAccount ==. val ai &&. t ^. M.WalletTxConfidence `in_`
                    valList validConfidence &&.
                    if offline
                        then unspent
                        else unspent ||. spentOffline
            where_ $
                if minconf == 0
                    then cond
                    else cond &&. limitConfirmations (Right t) minconf
            return $ sum_ (c ^. M.WalletCoinValue)
    case res of
        (Value (Just s):_) -> return $ floor (s :: Double)
        _                  -> return 0
  where
    validConfidence =
        TxPending :
        TxBuilding :
        [ TxOffline
        | offline ]

addressBalances
    :: MonadIO m
    => Entity M.Account
    -> CY.KeyIndex
    -> CY.KeyIndex
    -> AddressType
    -> Word32
    -> Bool
    -> SqlPersistT m [(CY.KeyIndex, BalanceInfo)]
addressBalances accE@(Entity ai _) iMin iMax addrType minconf offline
                                                              -- We keep our joins flat to improve performance in SQLite.
 = do
    res <-
        select $
        from $
        \(x `LeftOuterJoin` c `LeftOuterJoin` t `LeftOuterJoin` s `LeftOuterJoin` st) -> do
            let joinCond = st ?. M.WalletTxId ==. s ?. M.SpentCoinSpendingTx
            -- Do not join the spending information for offline transactions if we
            -- request the online balances. This will count the coin as unspent.
            on $
                if offline
                    then joinCond
                    else joinCond &&. st ?. M.WalletTxConfidence !=.
                         just (val TxOffline)
            on $
                s ?. M.SpentCoinAccount ==. c ?. M.WalletCoinAccount &&. s ?. M.SpentCoinHash ==.
                c ?.
                M.WalletCoinHash &&.
                s ?.
                M.SpentCoinPos ==.
                c ?.
                M.WalletCoinPos
            let txJoin =
                    t ?. M.WalletTxId ==. c ?. M.WalletCoinTx &&. t ?. M.WalletTxConfidence `in_`
                    valList validConfidence
            on $
                if minconf == 0
                    then txJoin
                    else txJoin &&. limitConfirmations (Left t) minconf
            on $ c ?. M.WalletCoinAddr ==. just (x ^. M.WalletAddrId)
            let limitIndex
                    | iMin == iMax = x ^. M.WalletAddrIndex ==. val iMin
                    | otherwise =
                        x ^. M.WalletAddrIndex >=. val iMin &&. x ^. M.WalletAddrIndex <=.
                        val iMax
            where_
                (x ^. M.WalletAddrAccount ==. val ai &&. limitIndex &&. x ^. M.WalletAddrIndex <.
                 subSelectAddrCount accE addrType &&.
                 x ^.
                 M.WalletAddrType ==.
                 val addrType)
            groupBy $ x ^. M.WalletAddrIndex
            let unspent = E.isNothing $ st ?. M.WalletTxId
                invalidTx = E.isNothing $ t ?. M.WalletTxId
            return
                ( x ^. M.WalletAddrIndex -- Address index
                , sum_ $
                  case_
                      [when_ invalidTx then_ (val (Just 0))]
                      (else_ $ c ?. M.WalletCoinValue) -- Out value
                , sum_ $
                  case_
                      [when_ (unspent ||. invalidTx) then_ (val (Just 0))]
                      (else_ $ c ?. M.WalletCoinValue) -- Out value
                , count $ t ?. M.WalletTxId -- New coins
                , count $
                  case_
                      [when_ invalidTx then_ (val Nothing)]
                      (else_ $ st ?. M.WalletTxId) -- Spent coins
                 )
    return $ map f res
  where
    validConfidence =
        Just TxPending :
        Just TxBuilding :
        [ Just TxOffline
        | offline ]
    f (Value i, Value inM, Value outM, Value newC, Value spentC) =
        let b =
                BalanceInfo
                { balanceInfoInBalance = floor $ fromMaybe (0 :: Double) inM
                , balanceInfoOutBalance = floor $ fromMaybe (0 :: Double) outM
                , balanceInfoCoins = newC
                , balanceInfoSpentCoins = spentC
                }
        in (i, b)

{- Rescans -}
resetRescan
    :: MonadIO m
    => SqlPersistT m ()
resetRescan = do
    P.deleteWhere ([] :: [P.Filter M.WalletCoin])
    P.deleteWhere ([] :: [P.Filter M.SpentCoin])
    P.deleteWhere ([] :: [P.Filter M.WalletTx])
    setBestBlock (headerHash genesisHeader) 0
