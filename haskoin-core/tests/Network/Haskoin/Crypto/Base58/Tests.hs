module Network.Haskoin.Crypto.Base58.Tests (tests) where

import           Test.Framework                       (Test, testGroup)
import           Test.Framework.Providers.QuickCheck2 (testProperty)

import           Data.String                          (fromString)
import           Data.String.Conversions              (cs)

import           Network.Haskoin.Crypto
import           Network.Haskoin.Test

tests :: [Test]
tests =
    [ testGroup "Address and Base58"
        [ testProperty "decode58( encode58(i) ) = i" decodeEncode58
        , testProperty "decode58Chk( encode58Chk(i) ) = i" decodeEncode58Check
        , testProperty "decode58( encode58(address) ) = address" decEncAddr
        , testProperty "Read/Show address" testReadShowAddress
        , testProperty "From string address" testFromStringAddress
        ]
    ]

decodeEncode58 :: ArbitraryByteString -> Bool
decodeEncode58 (ArbitraryByteString bs) =
    decodeBase58 (encodeBase58 bs) == Just bs

decodeEncode58Check :: ArbitraryByteString -> Bool
decodeEncode58Check (ArbitraryByteString bs) =
    decodeBase58Check (encodeBase58Check bs) == Just bs

decEncAddr :: ArbitraryAddress -> Bool
decEncAddr (ArbitraryAddress a) = base58ToAddr (addrToBase58 a) == Just a


testReadShowAddress :: ArbitraryAddress -> Bool
testReadShowAddress (ArbitraryAddress a) = read (show a) == a

testFromStringAddress :: ArbitraryAddress -> Bool
testFromStringAddress (ArbitraryAddress a) = fromString (cs $ addrToBase58 a) == a
