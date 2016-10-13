{-|
  Arbitrary types for Network.Haskoin.Node
-}
module Network.Haskoin.Test.Node
       ( ArbitraryVarInt(..)
       , ArbitraryVarString(..)
       , ArbitraryNetworkAddress(..)
       , ArbitraryNetworkAddressTime(..)
       , ArbitraryInvType(..)
       , ArbitraryInvVector(..)
       , ArbitraryInv(..)
       , ArbitraryVersion(..)
       , ArbitraryAddr(..)
       , ArbitraryAlert(..)
       , ArbitraryReject(..)
       , ArbitraryRejectCode(..)
       , ArbitraryGetData(..)
       , ArbitraryNotFound(..)
       , ArbitraryPing(..)
       , ArbitraryPong(..)
       , ArbitraryBloomFlags(..)
       , ArbitraryBloomFilter(..)
       , ArbitraryFilterLoad(..)
       , ArbitraryFilterAdd(..)
       , ArbitraryMessageCommand(..)
       ) where

import           Test.QuickCheck             (Arbitrary, arbitrary, choose,
                                              elements, listOf1, oneof,
                                              vectorOf)

import qualified Data.ByteString             as BS (empty, pack)
import           Data.Word                   (Word16, Word32)

import           Network.Socket              (SockAddr (..))

import qualified Network.Haskoin.Node        as N
import           Network.Haskoin.Test.Crypto (ArbitraryByteString (..),
                                              ArbitraryHash256 (..))

-- | Arbitrary VarInt
newtype ArbitraryVarInt =
    ArbitraryVarInt N.VarInt
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryVarInt where
    arbitrary = ArbitraryVarInt . N.VarInt <$> arbitrary

-- | Arbitrary VarString
newtype ArbitraryVarString =
    ArbitraryVarString N.VarString
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryVarString where
    arbitrary = do
        ArbitraryByteString bs <- arbitrary
        return $ ArbitraryVarString $ N.VarString bs

-- | Arbitrary NetworkAddress
newtype ArbitraryNetworkAddress =
    ArbitraryNetworkAddress N.NetworkAddress
    deriving (Eq, Show)

instance Arbitrary ArbitraryNetworkAddress where
    arbitrary = do
        s <- arbitrary
        a <- arbitrary
        p <- arbitrary
        ArbitraryNetworkAddress . N.NetworkAddress s <$>
            oneof
                [ do b <- arbitrary
                     c <- arbitrary
                     d <- arbitrary
                     return $ SockAddrInet6 (fromIntegral p) 0 (a, b, c, d) 0
                , return $ SockAddrInet (fromIntegral (p :: Word16)) a
                ]

-- | Arbitrary NetworkAddressTime
newtype ArbitraryNetworkAddressTime =
    ArbitraryNetworkAddressTime (Word32, N.NetworkAddress)

instance Arbitrary ArbitraryNetworkAddressTime where
    arbitrary = do
        w <- arbitrary
        ArbitraryNetworkAddress a <- arbitrary
        return $ ArbitraryNetworkAddressTime (w, a)

-- | Arbitrary InvType
newtype ArbitraryInvType =
    ArbitraryInvType N.InvType
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryInvType where
    arbitrary =
        ArbitraryInvType <$>
        elements [N.InvError, N.InvTx, N.InvBlock, N.InvMerkleBlock]

-- | Arbitrary InvVector
newtype ArbitraryInvVector =
    ArbitraryInvVector N.InvVector
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryInvVector where
    arbitrary = do
        ArbitraryInvType t <- arbitrary
        ArbitraryHash256 h <- arbitrary
        return $ ArbitraryInvVector $ N.InvVector t h

-- | Arbitrary non-empty Inv
newtype ArbitraryInv =
    ArbitraryInv N.Inv
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryInv where
    arbitrary = do
        vs <- listOf1 arbitrary
        return $ ArbitraryInv $ N.Inv $ map (\(ArbitraryInvVector v) -> v) vs

-- | Arbitrary Version
newtype ArbitraryVersion =
    ArbitraryVersion N.Version
    deriving (Eq, Show)

instance Arbitrary ArbitraryVersion where
    arbitrary = do
        v <- arbitrary
        s <- arbitrary
        t <- arbitrary
        ArbitraryNetworkAddress nr <- arbitrary
        ArbitraryNetworkAddress ns <- arbitrary
        n <- arbitrary
        ArbitraryVarString a <- arbitrary
        h <- arbitrary
        r <- arbitrary
        return $ ArbitraryVersion $ N.Version v s t nr ns n a h r

-- | Arbitrary non-empty Addr
newtype ArbitraryAddr =
    ArbitraryAddr N.Addr
    deriving (Eq, Show)

instance Arbitrary ArbitraryAddr where
    arbitrary = do
        vs <- listOf1 arbitrary
        return $
            ArbitraryAddr $ N.Addr $ map (\(ArbitraryNetworkAddressTime x) -> x) vs

-- | Arbitrary alert with random payload and signature. Signature is not
-- valid.
newtype ArbitraryAlert =
    ArbitraryAlert N.Alert
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryAlert where
    arbitrary = do
        ArbitraryVarString p <- arbitrary
        ArbitraryVarString s <- arbitrary
        return $ ArbitraryAlert $ N.Alert p s

-- | Arbitrary Reject
newtype ArbitraryReject =
    ArbitraryReject N.Reject
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryReject where
    arbitrary = do
        ArbitraryMessageCommand m <- arbitrary
        ArbitraryRejectCode c <- arbitrary
        ArbitraryVarString s <- arbitrary
        d <- oneof [return BS.empty, BS.pack <$> vectorOf 32 arbitrary]
        return $ ArbitraryReject $ N.Reject m c s d

-- | Arbitrary RejectCode
newtype ArbitraryRejectCode =
    ArbitraryRejectCode N.RejectCode
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryRejectCode where
    arbitrary =
        ArbitraryRejectCode <$>
        elements
            [ N.RejectMalformed
            , N.RejectInvalid
            , N.RejectInvalid
            , N.RejectDuplicate
            , N.RejectNonStandard
            , N.RejectDust
            , N.RejectInsufficientFee
            , N.RejectCheckpoint
            ]

-- | Arbitrary non-empty GetData
newtype ArbitraryGetData =
    ArbitraryGetData N.GetData
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryGetData where
    arbitrary = do
        vs <- listOf1 arbitrary
        return $
            ArbitraryGetData $ N.GetData $ map (\(ArbitraryInvVector x) -> x) vs

-- | Arbitrary NotFound
newtype ArbitraryNotFound =
    ArbitraryNotFound N.NotFound
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryNotFound where
    arbitrary = do
        vs <- listOf1 arbitrary
        return $
            ArbitraryNotFound $ N.NotFound $ map (\(ArbitraryInvVector x) -> x) vs

-- | Arbitrary Ping
newtype ArbitraryPing =
    ArbitraryPing N.Ping
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryPing where
    arbitrary = ArbitraryPing . N.Ping <$> arbitrary

-- | Arbitrary Pong
newtype ArbitraryPong =
    ArbitraryPong N.Pong
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryPong where
    arbitrary = ArbitraryPong . N.Pong <$> arbitrary

-- | Arbitrary bloom filter flags
data ArbitraryBloomFlags =
    ArbitraryBloomFlags N.BloomFlags
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryBloomFlags where
    arbitrary =
        ArbitraryBloomFlags <$>
        elements [N.BloomUpdateNone, N.BloomUpdateAll, N.BloomUpdateP2PubKeyOnly]

-- | Arbitrary bloom filter with its corresponding number of elements
-- and false positive rate.
data ArbitraryBloomFilter =
    ArbitraryBloomFilter Int
                         Double
                         N.BloomFilter
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryBloomFilter where
    arbitrary = do
        n <- choose (0, 100000)
        fp <- choose (1e-8, 1)
        tweak <- arbitrary
        ArbitraryBloomFlags fl <- arbitrary
        return $ ArbitraryBloomFilter n fp $ N.bloomCreate n fp tweak fl

-- | Arbitrary FilterLoad
data ArbitraryFilterLoad =
    ArbitraryFilterLoad N.FilterLoad
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryFilterLoad where
    arbitrary = do
        ArbitraryBloomFilter _ _ bf <- arbitrary
        return $ ArbitraryFilterLoad $ N.FilterLoad bf

-- | Arbitrary FilterAdd
data ArbitraryFilterAdd =
    ArbitraryFilterAdd N.FilterAdd
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryFilterAdd where
    arbitrary = do
        ArbitraryByteString bs <- arbitrary
        return $ ArbitraryFilterAdd $ N.FilterAdd bs

-- | Arbitrary MessageCommand
newtype ArbitraryMessageCommand =
    ArbitraryMessageCommand N.MessageCommand
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryMessageCommand where
    arbitrary =
        ArbitraryMessageCommand <$>
        elements
            [ N.MCVersion
            , N.MCVerAck
            , N.MCAddr
            , N.MCInv
            , N.MCGetData
            , N.MCNotFound
            , N.MCGetBlocks
            , N.MCGetHeaders
            , N.MCTx
            , N.MCBlock
            , N.MCMerkleBlock
            , N.MCHeaders
            , N.MCGetAddr
            , N.MCFilterLoad
            , N.MCFilterAdd
            , N.MCFilterClear
            , N.MCPing
            , N.MCPong
            , N.MCAlert
            ]
