{-|
  This package provides a command line application called /hw/ (haskoin
  wallet). It is a lightweight bitcoin wallet featuring BIP32 key management,
  deterministic signatures (RFC-6979) and first order support for
  multisignature transactions. A library API for /hw/ is also exposed.
-}
module Network.Haskoin.Wallet
  ( clientMain
  , OutputFormat(..)
  , Config(..)
  , runSPVServer
  , stopSPVServer
  , SPVMode(..)
  , JsonAccount(..)
  , JsonAddr(..)
  , JsonCoin(..)
  , JsonTx(..)
  , WalletRequest(..)
  , ListRequest(..)
  , NewAccount(..)
  , SetAccountGap(..)
  , OfflineTxData(..)
  , CoinSignData(..)
  , TxAction(..)
  , AddressLabel(..)
  , NodeAction(..)
  , AccountType(..)
  , AddressType(..)
  , addrTypeIndex
  , TxType(..)
  , TxConfidence(..)
  , AddressInfo(..)
  , BalanceInfo(..)
  , WalletResponse(..)
  , TxCompleteRes(..)
  , ListResult(..)
  , RescanRes(..)
  , initWallet
  , accounts
  , newAccount
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
  , setAccountGap
  , firstAddrTime
  , getPathRedeem
  , getPathPubKey
  , getBloomFilter
  , txs
  , addrTxs
  , getTx
  , getAccountTx
  , importTx
  , importNetTx
  , signAccountTx
  , createWalletTx
  , signOfflineTx
  , getOfflineTxData
  , importMerkles
  , walletBestBlock
  , spendableCoins
  , accountBalance
  , addressBalances
  , resetRescan
  ) where

-- *Client
-- *Server
-- *API JSON Types
-- *API Request Types
-- *API Response Types
-- *Database Accounts
-- *Database Addresses
-- *Database Bloom Filter
-- *Database transactions
-- *Database blocks
-- *Database coins and balances
-- *Rescan
import           Network.Haskoin.Wallet.Accounts
import           Network.Haskoin.Wallet.Client
import           Network.Haskoin.Wallet.Server
import           Network.Haskoin.Wallet.Settings
import           Network.Haskoin.Wallet.Transaction
import           Network.Haskoin.Wallet.Types
