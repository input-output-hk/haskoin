module Main where

import Test.Framework (defaultMain)

import qualified Network.Haskoin.Index.Tests (tests)
import qualified Network.Haskoin.Index.Units (tests)

main :: IO ()
main = defaultMain
    (  Network.Haskoin.Index.Tests.tests
    ++ Network.Haskoin.Index.Units.tests
    )

