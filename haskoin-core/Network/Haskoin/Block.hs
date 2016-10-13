{-|
  This package provides block and block-related types.
-}
module Network.Haskoin.Block
       (
         -- * Blocks
         Block(..)
       , BlockLocator
       , GetBlocks(..)

         -- * Block Headers
       , BlockHeader
       , createBlock
       , createBlockHeader
       , blockVersion
       , prevBlock
       , merkleRoot
       , blockTimestamp
       , blockBits
       , bhNonce
       , headerHash
       , GetHeaders(..)
       , Headers(..)
       , BlockHeaderCount
       , BlockHash(..)
       , blockHashToHex
       , hexToBlockHash

         -- * Merkle Blocks
       , MerkleBlock(..)
       , MerkleRoot
       , FlagBits
       , PartialMerkleTree
       , calcTreeHeight
       , calcTreeWidth
       , buildMerkleRoot
       , calcHash
       , buildPartialMerkle
       , extractMatches

         -- * Difficulty Target
       , decodeCompact
       , encodeCompact
       ) where

-- * Blocks
import           Network.Haskoin.Block.Merkle
import           Network.Haskoin.Block.Types
