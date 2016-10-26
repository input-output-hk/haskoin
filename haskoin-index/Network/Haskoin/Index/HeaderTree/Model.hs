{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}

module Network.Haskoin.Index.HeaderTree.Model
       ( EntityField (..)
       , NodeBlock (..)
       , NodeBestChain (..)
       , migrateHeaderTree
       ) where

import           Data.Word                              (Word32)
import           Database.Persist.Class                 (EntityField (..))
import           Database.Persist.TH                    (mkMigrate, mkPersist,
                                                         persistLowerCase, share,
                                                         sqlSettings)

import           Network.Haskoin.Index.HeaderTree.Types (BlockHeight, NodeHeader (..),
                                                         ShortHash, Work)

share
    [mkPersist sqlSettings, mkMigrate "migrateHeaderTree"]
    [persistLowerCase|
NodeBlock
    hash         ShortHash
    header       NodeHeader    maxlen=80
    work         Work
    height       BlockHeight
    chain        Word32
    UniqueHash   hash
    UniqueChain  chain height
    deriving     Show
    deriving     Eq
NodeBestChain
    hash         ShortHash
    height       BlockHeight
    UniqueHashC  hash
    UniqueHeight height
|]
