module Network.Haskoin.Crypto.ECDSA.Tests (tests) where

import           Test.Framework                       (Test, testGroup)
import           Test.Framework.Providers.QuickCheck2 (testProperty)

import           Data.Bits                            (testBit)
import qualified Data.ByteString                      as BS (index, length)
import           Data.Serialize                       (encode)

import           Network.Haskoin.Crypto
import           Network.Haskoin.Test

tests :: [Test]
tests =
    [ testGroup "ECDSA signatures"
        [ testProperty "Verify signature" testVerifySig
        , testProperty "S component <= order/2" $
            \(ArbitrarySignature _ _ sig) -> halfOrderSig sig
        ]
    , testGroup "ECDSA Binary"
        [ testProperty "Encoded signature is canonical" $
            \(ArbitrarySignature _ _ sig) -> testIsCanonical sig
        ]
    ]

{- ECDSA Signatures -}

halfOrderSig :: Signature -> Bool
halfOrderSig = isCanonicalHalfOrder

testVerifySig :: ArbitrarySignature -> Bool
testVerifySig (ArbitrarySignature msg key sig) =
    verifySig msg sig pubkey
  where
    pubkey = derivePubKey key

{- ECDSA Binary -}

-- github.com/bitcoin/bitcoin/blob/master/src/script.cpp
-- from function IsCanonicalSignature
testIsCanonical :: Signature -> Bool
testIsCanonical sig = not $
    -- Non-canonical signature: too short
    (len < 8) ||
    -- Non-canonical signature: too long
    (len > 72) ||
    -- Non-canonical signature: wrong type
    (BS.index s 0 /= 0x30) ||
    -- Non-canonical signature: wrong length marker
    (BS.index s 1 /= len - 2) ||
    -- Non-canonical signature: S length misplaced
    (5 + rlen >= len) ||
    -- Non-canonical signature: R+S length mismatch
    (rlen + slen + 6 /= len) ||
    -- Non-canonical signature: R value type mismatch
    (BS.index s 2 /= 0x02) ||
    -- Non-canonical signature: R length is zero
    (rlen == 0) ||
    -- Non-canonical signature: R value negative
    (testBit (BS.index s 4) 7) ||
    -- Non-canonical signature: R value excessively padded
    (  rlen > 1
    && BS.index s 4 == 0
    && not (testBit (BS.index s 5) 7)
    ) ||
    -- Non-canonical signature: S value type mismatch
    (BS.index s (fromIntegral rlen+4) /= 0x02) ||
    -- Non-canonical signature: S length is zero
    (slen == 0) ||
    -- Non-canonical signature: S value negative
    (testBit (BS.index s (fromIntegral rlen+6)) 7) ||
    -- Non-canonical signature: S value excessively padded
    (  slen > 1
    && BS.index s (fromIntegral rlen+6) == 0
    && not (testBit (BS.index s (fromIntegral rlen+7)) 7)
    )
  where
    s = encode sig
    len = fromIntegral $ BS.length s
    rlen = BS.index s 3
    slen = BS.index s (fromIntegral rlen + 5)
