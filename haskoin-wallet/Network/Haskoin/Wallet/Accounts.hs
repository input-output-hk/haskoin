{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Network.Haskoin.Wallet.Accounts
       ( initWallet
       , accounts
       , newAccount
       , renameAccount
       , addAccountKeys
       , getAccount
       , isMultisigAccount
       , isReadAccount
       , isCompleteAccount
       , getAddress
       , addressesAll
       , addresses
       , addressList
       , unusedAddresses
       , addressCount
       , setAddrLabel
       , addressPrvKey
       , useAddress
       , generateAddrs
       , setAccountGap
       , firstAddrTime
       , getPathRedeem
       , getPathPubKey
       , getBloomFilter
       , subSelectAddrCount
       ) where

-- *Database Wallet
-- *Database Accounts
-- *Database Addresses
-- *Database Bloom Filter
-- * Helpers
import           Control.Applicative             ((<|>))
import           Control.Exception               (throw)
import           Control.Monad                   (unless, void, when)
import           Control.Monad.Base              (MonadBase)
import           Control.Monad.Catch             (MonadThrow, throwM)
import           Control.Monad.Trans             (MonadIO, liftIO)
import           Control.Monad.Trans.Resource    (MonadResource)

import           Data.List                       (nub)
import           Data.Maybe                      (isJust, isNothing,
                                                  listToMaybe, mapMaybe)
import           Data.Serialize                  (encode)
import           Data.String.Conversions         (cs)
import           Data.Text                       (Text, unpack)
import           Data.Time.Clock                 (getCurrentTime)
import           Data.Time.Clock.POSIX           (utcTimeToPOSIXSeconds)
import           Data.Word                       (Word32)

import           Database.Esqueleto              (Entity (..), SqlExpr,
                                                  SqlPersistT, Value (..), asc,
                                                  case_, count, countDistinct,
                                                  countRows, desc, else_, from,
                                                  get, insertUnique, insert_,
                                                  limit, max_, offset, orderBy,
                                                  select, sub_select, then_,
                                                  unValue, val, when_, where_,
                                                  (&&.), (-.), (<.), (==.),
                                                  (>.), (^.))
import qualified Database.Persist                as P (update, updateWhere,
                                                       (=.))

import           Network.Haskoin.Block           (headerHash)
import           Network.Haskoin.Constants       (genesisHeader)
import qualified Network.Haskoin.Crypto          as CY
import           Network.Haskoin.Node            (BloomFilter, BloomFlags (..),
                                                  bloomCreate, bloomInsert)
import           Network.Haskoin.Node.HeaderTree (Timestamp)
import           Network.Haskoin.Script          (RedeemScript,
                                                  ScriptOutput (..),
                                                  encodeOutputBS, sortMulSig)
import           Network.Haskoin.Util            (fromRight)

import qualified Network.Haskoin.Wallet.Model    as WM
import qualified  Network.Haskoin.Wallet.Types   as WT

{- Initialization -}
initWallet
    :: MonadIO m
    => Double -> SqlPersistT m ()
initWallet fpRate = do
    prevConfigRes <- select $ from $ \c -> return $ count $ c ^. WM.WalletStateId
    let cnt = maybe 0 unValue $ listToMaybe prevConfigRes
    when (cnt == (0 :: Int)) $
        do time <- liftIO getCurrentTime
           -- Create an initial bloom filter
           -- TODO: Compute a random nonce
           let bloom = bloomCreate (filterLen 0) fpRate 0 BloomUpdateNone
           insert_
               WM.WalletState
               { walletStateHeight = 0
               , walletStateBlock = headerHash genesisHeader
               , walletStateBloomFilter = bloom
               , walletStateBloomElems = 0
               , walletStateBloomFp = fpRate
               , walletStateVersion = 1
               , walletStateCreated = time
               }

{- Account -}
-- | Fetch all accounts
accounts
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => WT.ListRequest -> SqlPersistT m ([WM.Account], Word32)
accounts WT.ListRequest {..} = do
    cntRes <- select $ from $ \acc -> return $ countDistinct $ acc ^. WM.AccountId
    let cnt = maybe 0 unValue $ listToMaybe cntRes
    when (listOffset > 0 && listOffset >= cnt) $
        throw $ WT.WalletException "Offset beyond end of data set"
    res <-
        fmap (map entityVal) $
        select $
        from $
        \acc -> do
            WT.limitOffset listLimit listOffset
            return acc
    return (res, cnt)

initGap
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => Entity WM.Account -> SqlPersistT m ()
initGap accE = do
    void $ createAddrs accE WT.AddressExternal 20
    void $ createAddrs accE WT.AddressInternal 20

-- | Create a new account
newAccount
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => WT.NewAccount -> SqlPersistT m (Entity WM.Account, Maybe CY.Mnemonic)
newAccount WT.NewAccount {..} = do
    unless (validAccountType newAccountType) $
        throwM $ WT.WalletException "Invalid account type"
    let gen =
            isNothing newAccountMnemonic && isNothing newAccountMaster && null newAccountKeys
    (mnemonicM, masterM, keys) <-
        if gen
            then do
                when (isJust newAccountMaster || isJust newAccountMnemonic) $
                    throwM $
                    WT.WalletException
                        "Master key or mnemonic not allowed for generate"
                ent <- liftIO $ CY.getEntropy 16
                let ms = fromRight $ CY.toMnemonic ent
                    root = CY.makeXPrvKey $ fromRight $ CY.mnemonicToSeed "" ms
                    master =
                        case newAccountDeriv of
                            Nothing -> root
                            Just d  -> CY.derivePath d root
                    keys = CY.deriveXPubKey master : newAccountKeys
                return (Just ms, Just master, keys)
            else case newAccountMnemonic of
                     Just ms -> do
                         when (isJust newAccountMaster) $
                             throwM $
                             WT.WalletException
                                 "Cannot provide both master key and mnemonic"
                         root <-
                             case CY.mnemonicToSeed "" (cs ms) of
                                 Right s -> return $ CY.makeXPrvKey s
                                 Left _ ->
                                     throwM $
                                     WT.WalletException "Mnemonic sentence invalid"
                         let master =
                                 case newAccountDeriv of
                                     Nothing -> root
                                     Just d  -> CY.derivePath d root
                             keys = CY.deriveXPubKey master : newAccountKeys
                         return (Nothing, Just master, keys)
                     Nothing ->
                         case newAccountMaster of
                             Just master -> do
                                 let keys = CY.deriveXPubKey master : newAccountKeys
                                 return (Nothing, newAccountMaster, keys)
                             Nothing ->
                                 return
                                     (Nothing, newAccountMaster, newAccountKeys)
    -- Build the account
    now <- liftIO getCurrentTime
    let acc =
            WM.Account
            { accountName = newAccountName
            , accountType = newAccountType
            , accountMaster =
                if newAccountReadOnly
                    then Nothing
                    else masterM
            , accountDerivation = newAccountDeriv
            , accountKeys = nub keys
            , accountGap = 0
            , accountCreated = now
            }
    -- Check if all the keys are valid
    unless (isValidAccKeys acc) $
        throwM $ WT.WalletException "Invalid account keys"
    -- Insert our account in the database
    let canSetGap = isCompleteAccount acc
        newAcc =
            acc
            { WM.accountGap =
                if canSetGap
                    then 10
                    else 0
            }
    insertUnique newAcc >>=
        \resM ->
             case resM
                  -- The account got created.
                   of
                 Just ai -> do
                     let accE = Entity ai newAcc
                     -- If we can set the gap, create the gap addresses
                     when canSetGap $ initGap accE
                     return (accE, mnemonicM)
                 -- The account already exists
                 Nothing -> throwM $ WT.WalletException "Account already exists"

renameAccount
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => Entity WM.Account -> WT.AccountName -> SqlPersistT m WM.Account
renameAccount (Entity ai acc) name = do
    P.update ai [WM.AccountName P.=. name]
    return $
        acc
        { WM.accountName = name
        }

-- | Add new thirdparty keys to a multisignature account. This function can
-- fail if the multisignature account already has all required keys.
addAccountKeys
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => Entity WM.Account -- ^ Account Entity
    -> [CY.XPubKey] -- ^ Thirdparty public keys to add
    -> SqlPersistT m WM.Account -- ^ Account information
addAccountKeys (Entity ai acc) keys
                               -- We can only add keys on incomplete accounts
    | isCompleteAccount acc =
        throwM $ WT.WalletException "The account is already complete"
    | null keys || not (isValidAccKeys accKeys) =
        throwM $ WT.WalletException "Invalid account keys"
    | otherwise = do
        let canSetGap = isCompleteAccount accKeys
            updGap =
                [ WM.AccountGap P.=. 10
                | canSetGap ]
            newAcc =
                accKeys
                { WM.accountGap =
                    if canSetGap
                        then 10
                        else 0
                }
        -- Update the account with the keys and the new gap if it is complete
        P.update ai $ (WM.AccountKeys P.=. newKeys) : updGap
        -- If we can set the gap, create the gap addresses
        when canSetGap $ initGap $ Entity ai newAcc
        return newAcc
  where
    newKeys = WM.accountKeys acc ++ keys
    accKeys =
        acc
        { WM.accountKeys = newKeys
        }

isValidAccKeys :: WM.Account -> Bool
isValidAccKeys WM.Account {..} =
    testMaster &&
    case accountType of
        WT.AccountRegular      -> length accountKeys == 1
        WT.AccountMultisig _ n -> goMultisig n
  where
    goMultisig n =
        length accountKeys == length (nub accountKeys) &&
        length accountKeys <= n && not (null accountKeys)
    testMaster =
        case accountMaster of
            Just m  -> CY.deriveXPubKey m `elem` accountKeys
            Nothing -> True

-- Helper functions to get an Account if it exists, or throw an exception
-- otherwise.
getAccount
    :: (MonadIO m, MonadThrow m)
    => WT.AccountName -> SqlPersistT m (Entity WM.Account)
getAccount accountName = do
    as <-
        select $
        from $
        \a -> do
            where_ $ a ^. WM.AccountName ==. val accountName
            return a
    case as of
        (accEnt:_) -> return accEnt
        _ ->
            throwM $
            WT.WalletException $
            unwords ["Account", unpack accountName, "does not exist"]

{- Addresses -}
-- | Get an address if it exists, or throw an exception otherwise. Fetching
-- addresses in the hidden gap will also throw an exception.
getAddress
    :: (MonadIO m, MonadThrow m)
    => Entity WM.Account -- ^ Account Entity
    -> WT.AddressType -- ^ Address type
    -> CY.KeyIndex -- ^ Derivation index (key)
    -> SqlPersistT m (Entity WM.WalletAddr) -- ^ Address
getAddress accE@(Entity ai _) addrType index = do
    res <-
        select $
        from $
        \x -> do
            where_
                (x ^. WM.WalletAddrAccount ==. val ai &&. x ^. WM.WalletAddrType ==.
                 val addrType &&.
                 x ^.
                 WM.WalletAddrIndex ==.
                 val index &&.
                 x ^.
                 WM.WalletAddrIndex <.
                 subSelectAddrCount accE addrType)
            limit 1
            return x
    case res of
        (addrE:_) -> return addrE
        _ ->
            throwM $
            WT.WalletException $ unwords ["Invalid address index", show index]

-- | All addresses in the wallet, including hidden gap addresses. This is useful
-- for building a bloom filter.
addressesAll
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => SqlPersistT m [WM.WalletAddr]
addressesAll = fmap (map entityVal) $ select $ from return

-- | All addresses in one account excluding hidden gap.
addresses
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => Entity WM.Account -- ^ Account Entity
    -> WT.AddressType -- ^ Address Type
    -> SqlPersistT m [WM.WalletAddr] -- ^ Addresses
addresses accE@(Entity ai _) addrType =
    fmap (map entityVal) $
    select $
    from $
    \x -> do
        where_
            (x ^. WM.WalletAddrAccount ==. val ai &&. x ^. WM.WalletAddrType ==. val addrType &&.
             x ^.
             WM.WalletAddrIndex <.
             subSelectAddrCount accE addrType)
        return x

-- | Get address list.
addressList
    :: MonadIO m
    => Entity WM.Account -- ^ Account Entity
    -> WT.AddressType -- ^ Address type
    -> WT.ListRequest -- ^ List request
    -> SqlPersistT m ([WM.WalletAddr], Word32) -- ^ List result
addressList accE@(Entity ai _) addrType WT.ListRequest {..} = do
    cnt <- addressCount accE addrType
    when (listOffset > 0 && listOffset >= cnt) $
        throw $ WT.WalletException "Offset beyond end of data set"
    res <-
        fmap (map entityVal) $
        select $
        from $
        \x -> do
            where_
                (x ^. WM.WalletAddrAccount ==. val ai &&. x ^. WM.WalletAddrType ==.
                 val addrType &&.
                 x ^.
                 WM.WalletAddrIndex <.
                 val cnt)
            let order =
                    if listReverse
                        then asc
                        else desc
            orderBy [order (x ^. WM.WalletAddrIndex)]
            when (listLimit > 0) $ limit $ fromIntegral listLimit
            when (listOffset > 0) $ offset $ fromIntegral listOffset
            return x
    return (res, cnt)

-- | Get a count of all the addresses in an account
addressCount
    :: MonadIO m
    => Entity WM.Account -- ^ Account Entity
    -> WT.AddressType -- ^ Address type
    -> SqlPersistT m Word32 -- ^ Address Count
addressCount (Entity ai acc) addrType = do
    res <-
        select $
        from $
        \x -> do
            where_
                (x ^. WM.WalletAddrAccount ==. val ai &&. x ^. WM.WalletAddrType ==.
                 val addrType)
            return countRows
    let cnt = maybe 0 unValue $ listToMaybe res
    return $
        if cnt > WM.accountGap acc
            then cnt - WM.accountGap acc
            else 0

-- | Get a list of all unused addresses.
unusedAddresses
    :: MonadIO m
    => Entity WM.Account -- ^ Account ID
    -> WT.AddressType -- ^ Address type
    -> WT.ListRequest
    -> SqlPersistT m ([WM.WalletAddr], Word32) -- ^ Unused addresses
unusedAddresses (Entity ai acc) addrType WT.ListRequest {..} = do
    cntRes <-
        select $
        from $
        \x -> do
            where_
                (x ^. WM.WalletAddrAccount ==. val ai &&. x ^. WM.WalletAddrType ==.
                 val addrType)
            return countRows
    let cnt = maybe 0 unValue $ listToMaybe cntRes
    when (listOffset > 0 && listOffset >= gap) $
        throw $ WT.WalletException "Offset beyond end of data set"
    res <-
        fmap (map entityVal) $
        select $
        from $
        \x -> do
            where_
                (x ^. WM.WalletAddrAccount ==. val ai &&. x ^. WM.WalletAddrType ==.
                 val addrType)
            orderBy [order $ x ^. WM.WalletAddrIndex]
            limit $ fromIntegral $ lim cnt
            offset $ fromIntegral $ off cnt
            return x
    return (res, gap)
  where
    gap = WM.accountGap acc
    lim' =
        if listLimit > 0
            then listLimit
            else gap
    off cnt
        | listReverse = listOffset + gap
        | otherwise = cnt - 2 * gap + listOffset
    lim cnt
        | listReverse = min lim' (gap - listOffset)
        | otherwise = min lim' (cnt - off cnt - gap)
    order =
        if listReverse
            then desc
            else asc

-- | Add a label to an address.
setAddrLabel
    :: (MonadIO m, MonadThrow m)
    => Entity WM.Account -- ^ Account ID
    -> CY.KeyIndex -- ^ Derivation index
    -> WT.AddressType -- ^ Address type
    -> Text -- ^ New label
    -> SqlPersistT m WM.WalletAddr
setAddrLabel accE i addrType label = do
    Entity addrI addr <- getAddress accE addrType i
    P.update addrI [WM.WalletAddrLabel P.=. label]
    return $
        addr
        { WM.walletAddrLabel = label
        }

-- | Returns the private key of an address.
addressPrvKey
    :: (MonadIO m, MonadThrow m)
    => Entity WM.Account -- ^ Account Entity
    -> Maybe CY.XPrvKey -- ^ If not in account
    -> CY.KeyIndex -- ^ Derivation index of the address
    -> WT.AddressType -- ^ Address type
    -> SqlPersistT m CY.PrvKeyC -- ^ Private key
addressPrvKey accE@(Entity ai acc) masterM index addrType = do
    ret <-
        select $
        from $
        \x -> do
            where_
                (x ^. WM.WalletAddrAccount ==. val ai &&. x ^. WM.WalletAddrType ==.
                 val addrType &&.
                 x ^.
                 WM.WalletAddrIndex ==.
                 val index &&.
                 x ^.
                 WM.WalletAddrIndex <.
                 subSelectAddrCount accE addrType)
            return $ x ^. WM.WalletAddrIndex
    case ret of
        (Value idx:_) -> do
            accKey <-
                case WM.accountMaster acc <|> masterM of
                    Just key -> return key
                    Nothing ->
                        throwM $ WT.WalletException "Could not get private key"
            let addrKey =
                    CY.prvSubKey (CY.prvSubKey accKey (WT.addrTypeIndex addrType)) idx
            return $ CY.xPrvKey addrKey
        _ -> throwM $ WT.WalletException "Invalid address"

-- | Create new addresses in an account and increment the internal bloom filter.
-- This is a low-level function that simply creates the desired amount of new
-- addresses in an account, disregarding visible and hidden address gaps. You
-- should use the function `setAccountGap` if you want to control the gap of an
-- account instead.
createAddrs
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => Entity WM.Account -> WT.AddressType -> Word32 -> SqlPersistT m [WM.WalletAddr]
createAddrs (Entity ai acc) addrType n
    | n == 0 = throwM $ WT.WalletException $ unwords ["Invalid value", show n]
    | not (isCompleteAccount acc) =
        throwM $
        WT.WalletException $
        unwords
            [ "Keys are still missing from the incomplete account"
            , unpack $ WM.accountName acc
            ]
    | otherwise = do
        now <- liftIO getCurrentTime
        -- Find the next derivation index from the last address
        lastRes <-
            select $
            from $
            \x -> do
                where_
                    (x ^. WM.WalletAddrAccount ==. val ai &&. x ^. WM.WalletAddrType ==.
                     val addrType)
                return $ max_ (x ^. WM.WalletAddrIndex)
        let nextI =
                case lastRes of
                    (Value (Just lastI):_) -> lastI + 1
                    _                      -> 0
            build (addr, keyM, rdmM, i) =
                WM.WalletAddr
                { walletAddrAccount = ai
                , walletAddrAddress = addr
                , walletAddrIndex = i
                , walletAddrType = addrType
                , walletAddrLabel = ""
                , walletAddrRedeem = rdmM
                , walletAddrKey = keyM
                , walletAddrCreated = now
                }
            res = map build $ take (fromIntegral n) $ deriveFrom nextI
        -- Save the addresses and increment the bloom filter
        WT.splitInsertMany_ res
        incrementFilter res
        return res
  where
    branchType = WT.addrTypeIndex addrType
    deriveFrom =
        case WM.accountType acc of
            WT.AccountMultisig m _ ->
                let f (a, r, i) = (a, Nothing, Just r, i)
                    deriv = CY.Deriv CY.:/ branchType
                in map f . CY.derivePathMSAddrs (WM.accountKeys acc) deriv m
            WT.AccountRegular ->
                case WM.accountKeys acc of
                    (key:_) ->
                        let f (a, k, i) = (a, Just k, Nothing, i)
                        in map f . CY.derivePathAddrs key (CY.Deriv CY.:/ branchType)
                    [] ->
                        throw $
                        WT.WalletException $
                        unwords
                            [ "createAddrs: No key in regular account (corrupt database)"
                            , unpack $ WM.accountName acc
                            ]

-- Branch type (external = 0, internal = 1)
-- | Generate all the addresses up to certain index.
generateAddrs
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => Entity WM.Account -> WT.AddressType -> CY.KeyIndex -> SqlPersistT m Int
generateAddrs accE addrType genIndex = do
    cnt <- addressCount accE addrType
    let toGen = fromIntegral genIndex - fromIntegral cnt + 1
    if toGen > 0
        then do
            void $ createAddrs accE addrType $ fromIntegral toGen
            return toGen
        else return 0

-- | Use an address and make sure we have enough gap addresses after it.
-- Returns the new addresses that have been created.
useAddress
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => WM.WalletAddr -> SqlPersistT m [WM.WalletAddr]
useAddress WM.WalletAddr {..} = do
    res <-
        select $
        from $
        \x -> do
            where_
                (x ^. WM.WalletAddrAccount ==. val walletAddrAccount &&. x ^. WM.WalletAddrType ==.
                 val walletAddrType &&.
                 x ^.
                 WM.WalletAddrIndex >.
                 val walletAddrIndex)
            return countRows
    case res of
        (Value cnt:_) ->
            get walletAddrAccount >>=
            \accM ->
                 case accM of
                     Just acc -> do
                         let accE = Entity walletAddrAccount acc
                             gap = fromIntegral (WM.accountGap acc) :: Int
                             missing = 2 * gap - cnt
                         if missing > 0
                             then createAddrs accE walletAddrType $
                                  fromIntegral missing
                             else return []
                     _ -> return [] -- Should not happen
        _ -> return [] -- Should not happen

-- | Set the address gap of an account to a new value. This will create new
-- internal and external addresses as required. The gap can only be increased,
-- not decreased in size.
setAccountGap
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => Entity WM.Account -- ^ Account Entity
    -> Word32 -- ^ New gap value
    -> SqlPersistT m (Entity WM.Account)
setAccountGap accE@(Entity ai acc) gap
    | not (isCompleteAccount acc) =
        throwM $
        WT.WalletException $
        unwords
            [ "Keys are still missing from the incomplete account"
            , unpack $ WM.accountName acc
            ]
    | missing <= 0 =
        throwM $ WT.WalletException "The gap of an account can only be increased"
    | otherwise = do
        _ <- createAddrs accE WT.AddressExternal $ fromInteger $ missing * 2
        _ <- createAddrs accE WT.AddressInternal $ fromInteger $ missing * 2
        P.update ai [WM.AccountGap P.=. gap]
        return $
            Entity
                ai
                acc
                { WM.accountGap = gap
                }
  where
    missing = toInteger gap - toInteger (WM.accountGap acc)

-- Return the creation time of the first address in the wallet.
firstAddrTime
    :: MonadIO m
    => SqlPersistT m (Maybe Timestamp)
firstAddrTime = do
    res <-
        select $
        from $
        \x -> do
            orderBy [asc (x ^. WM.WalletAddrId)]
            limit 1
            return $ x ^. WM.WalletAddrCreated
    return $
        case res of
            (Value d:_) -> Just $ toPOSIX d
            _           -> Nothing
  where
    toPOSIX = fromInteger . round . utcTimeToPOSIXSeconds

{- Bloom filters -}
-- | Add the given addresses to the bloom filter. If the number of elements
-- becomes too large, a new bloom filter is computed from scratch.
incrementFilter
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => [WM.WalletAddr] -> SqlPersistT m ()
incrementFilter addrs = do
    (bloom, elems, _) <- getBloomFilter
    let newElems = elems + (length addrs * 2)
    if filterLen newElems > filterLen elems
        then computeNewFilter
        else setBloomFilter (addToFilter bloom addrs) newElems

-- | Generate a new bloom filter from the data in the database
computeNewFilter
    :: (MonadIO m, MonadThrow m, MonadBase IO m, MonadResource m)
    => SqlPersistT m ()
computeNewFilter = do
    (_, _, fpRate) <- getBloomFilter
    -- Create a new empty bloom filter
    -- TODO: Choose a random nonce for the bloom filter
    -- TODO: Check global bloom filter length limits
    cntRes <- select $ from $ \x -> return $ count $ x ^. WM.WalletAddrId
    let elems = maybe 0 unValue $ listToMaybe cntRes
        newBloom = bloomCreate (filterLen elems) fpRate 0 BloomUpdateNone
    addrs <- addressesAll
    let bloom = addToFilter newBloom addrs
    setBloomFilter bloom elems

-- Compute the size of a filter given a number of elements. Scale
-- the filter length by powers of 2.
filterLen :: Int -> Int
filterLen = round . pow2 . ceiling . log2
  where
    pow2 x = (2 :: Double) ** fromInteger x
    log2 x = logBase (2 :: Double) (fromIntegral x)

-- | Add elements to a bloom filter
addToFilter :: BloomFilter -> [WM.WalletAddr] -> BloomFilter
addToFilter bloom addrs = bloom3
  where
    pks = mapMaybe WM.walletAddrKey addrs
    rdms = mapMaybe WM.walletAddrRedeem addrs
    -- Add the Hash160 of the addresses
    f1 b a = bloomInsert b $ encode $ CY.getAddrHash a
    bloom1 = foldl f1 bloom $ map WM.walletAddrAddress addrs
    -- Add the redeem scripts
    f2 b r = bloomInsert b $ encodeOutputBS r
    bloom2 = foldl f2 bloom1 rdms
    -- Add the public keys
    f3 b p = bloomInsert b $ encode p
    bloom3 = foldl f3 bloom2 pks

-- | Returns a bloom filter containing all the addresses in this wallet. This
-- includes internal and external addresses. The bloom filter can be set on a
-- peer connection to filter the transactions received by that peer.
getBloomFilter
    :: (MonadIO m, MonadThrow m)
    => SqlPersistT m (BloomFilter, Int, Double)
getBloomFilter = do
    res <-
        select $
        from $
        \c -> do
            limit 1
            return
                (c ^. WM.WalletStateBloomFilter, c ^. WM.WalletStateBloomElems, c ^. WM.WalletStateBloomFp)
    case res of
        ((Value b, Value n, Value fp):_) -> return (b, n, fp)
        _ -> throwM $ WT.WalletException "getBloomFilter: Database not initialized"

-- | Save a bloom filter and the number of elements it contains
setBloomFilter
    :: MonadIO m
    => BloomFilter -> Int -> SqlPersistT m ()
setBloomFilter bloom elems =
    P.updateWhere
        []
        [WM.WalletStateBloomFilter P.=. bloom, WM.WalletStateBloomElems P.=. elems]

-- Helper function to compute the redeem script of a given derivation path
-- for a given multisig account.
getPathRedeem :: WM.Account -> CY.SoftPath -> RedeemScript
getPathRedeem acc@WM.Account {..} deriv =
    case accountType of
        WT.AccountMultisig m _ ->
            if isCompleteAccount acc
                then sortMulSig $ PayMulSig pubKeys m
                else throw $
                     WT.WalletException $
                     unwords
                         [ "getPathRedeem: Incomplete multisig account"
                         , unpack accountName
                         ]
        _ ->
            throw $
            WT.WalletException $
            unwords
                [ "getPathRedeem: Account"
                , unpack accountName
                , "is not a multisig account"
                ]
  where
    f = CY.toPubKeyG . CY.xPubKey . CY.derivePubPath deriv
    pubKeys = map f accountKeys

-- Helper function to compute the public key of a given derivation path for
-- a given non-multisig account.
getPathPubKey :: WM.Account -> CY.SoftPath -> CY.PubKeyC
getPathPubKey acc@WM.Account {..} deriv
    | isMultisigAccount acc =
        throw $
        WT.WalletException $
        unwords
            [ "getPathPubKey: Account"
            , unpack accountName
            , "is not a regular non-multisig account"
            ]
    | otherwise =
        case accountKeys of
            (key:_) -> CY.xPubKey $ CY.derivePubPath deriv key
            _ ->
                throw $
                WT.WalletException $
                unwords
                    [ "getPathPubKey: No keys are available in account"
                    , unpack accountName
                    ]

{- Helpers -}
subSelectAddrCount :: Entity WM.Account -> WT.AddressType -> SqlExpr (Value CY.KeyIndex)
subSelectAddrCount (Entity ai acc) addrType =
    sub_select $
    from $
    \x -> do
        where_
            (x ^. WM.WalletAddrAccount ==. val ai &&. x ^. WM.WalletAddrType ==. val addrType)
        let gap = val $ WM.accountGap acc
        return $
            case_
                [when_ (countRows >. gap) then_ (countRows -. gap)]
                (else_ $ val 0)

validMultisigParams :: Int -> Int -> Bool
validMultisigParams m n = n >= 1 && n <= 15 && m >= 1 && m <= n

validAccountType :: WT.AccountType -> Bool
validAccountType t =
    case t of
        WT.AccountRegular      -> True
        WT.AccountMultisig m n -> validMultisigParams m n

isMultisigAccount :: WM.Account -> Bool
isMultisigAccount acc =
    case WM.accountType acc of
        WT.AccountRegular     -> False
        WT.AccountMultisig {} -> True

isReadAccount :: WM.Account -> Bool
isReadAccount = isNothing . WM.accountMaster

isCompleteAccount :: WM.Account -> Bool
isCompleteAccount acc =
    case WM.accountType acc of
        WT.AccountRegular      -> length (WM.accountKeys acc) == 1
        WT.AccountMultisig _ n -> length (WM.accountKeys acc) == n
