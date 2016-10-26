<<<<<<< HEAD:haskoin-node/tests/Network/Haskoin/Node/Tests.hs
module Network.Haskoin.Node.Tests
  ( tests
  ) where
=======
module Network.Haskoin.Index.Tests (tests) where
>>>>>>> origin/address-index:haskoin-index/tests/Network/Haskoin/Index/Tests.hs

import           Test.Framework (Test, testGroup)

-- import Test.Framework.Providers.QuickCheck2 (testProperty)
tests :: [Test]
tests = [testGroup "Serialize & de-serialize haskoin node types to JSON" []]
