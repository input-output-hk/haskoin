{-|
  Arbitrary types for Network.Haskoin.Node.Message
-}
module Network.Haskoin.Test.Message
       ( ArbitraryMessageHeader(..)
       , ArbitraryMessage(..)
       ) where

import           Test.QuickCheck                  (Arbitrary, arbitrary, oneof)

import           Network.Haskoin.Test.Block       (ArbitraryBlock (..),
                                                   ArbitraryGetBlocks (..),
                                                   ArbitraryGetHeaders (..),
                                                   ArbitraryHeaders (..),
                                                   ArbitraryMerkleBlock (..))
import           Network.Haskoin.Test.Crypto      (ArbitraryCheckSum32 (..))
import qualified Network.Haskoin.Test.Node        as N
import           Network.Haskoin.Test.Transaction (ArbitraryTx (..))

import qualified Network.Haskoin.Node.Message     as M

-- | Arbitrary MessageHeader
newtype ArbitraryMessageHeader =
    ArbitraryMessageHeader M.MessageHeader
    deriving (Eq, Show, Read)

instance Arbitrary ArbitraryMessageHeader where
    arbitrary =
        ArbitraryMessageHeader <$>
        do m <- arbitrary
           N.ArbitraryMessageCommand mc <- arbitrary
           p <- arbitrary
           ArbitraryCheckSum32 c <- arbitrary
           return $ M.MessageHeader m mc p c

-- | Arbitrary Message
newtype ArbitraryMessage =
    ArbitraryMessage M.Message
    deriving (Eq, Show)

instance Arbitrary ArbitraryMessage where
    arbitrary =
        ArbitraryMessage <$>
        oneof
            [ arbitrary >>= \(N.ArbitraryVersion x) -> return $ M.MVersion x
            , return M.MVerAck
            , arbitrary >>= \(N.ArbitraryAddr x) -> return $ M.MAddr x
            , arbitrary >>= \(N.ArbitraryInv x) -> return $ M.MInv x
            , arbitrary >>= \(N.ArbitraryGetData x) -> return $ M.MGetData x
            , arbitrary >>= \(N.ArbitraryNotFound x) -> return $ M.MNotFound x
            , arbitrary >>= \(ArbitraryGetBlocks x) -> return $ M.MGetBlocks x
            , arbitrary >>= \(ArbitraryGetHeaders x) -> return $ M.MGetHeaders x
            , arbitrary >>= \(ArbitraryTx x) -> return $ M.MTx x
            , arbitrary >>= \(ArbitraryBlock x) -> return $ M.MBlock x
            , arbitrary >>= \(ArbitraryMerkleBlock x) -> return $ M.MMerkleBlock x
            , arbitrary >>= \(ArbitraryHeaders x) -> return $ M.MHeaders x
            , return M.MGetAddr
            , arbitrary >>= \(N.ArbitraryFilterLoad x) -> return $ M.MFilterLoad x
            , arbitrary >>= \(N.ArbitraryFilterAdd x) -> return $ M.MFilterAdd x
            , return M.MFilterClear
            , arbitrary >>= \(N.ArbitraryPing x) -> return $ M.MPing x
            , arbitrary >>= \(N.ArbitraryPong x) -> return $ M.MPong x
            , arbitrary >>= \(N.ArbitraryAlert x) -> return $ M.MAlert x
            , arbitrary >>= \(N.ArbitraryReject x) -> return $ M.MReject x
            ]
