{-|
  This package provides functions for parsing and evaluating bitcoin
  transaction scripts. Data types are provided for building and
  deconstructing all of the standard input and output script types.
-}
module Network.Haskoin.Script
  ( Script(..)
  , ScriptOp(..)
  , PushDataType(..)
  , opPushData
   -- *Script Parsing
   -- **Script Outputs
  , ScriptOutput(..)
  , encodeOutput
  , encodeOutputBS
  , decodeOutput
  , decodeOutputBS
  , isPayPK
  , isPayPKHash
  , isPayMulSig
  , isPayScriptHash
  , scriptAddr
  , sortMulSig
   -- **Script Inputs
  , ScriptInput(..)
  , SimpleInput(..)
  , RedeemScript
  , encodeInput
  , encodeInputBS
  , decodeInput
  , decodeInputBS
  , isSpendPK
  , isSpendPKHash
  , isSpendMulSig
  , isScriptHashInput
   -- * Helpers
  , inputAddress
  , outputAddress
  , intToScriptOp
  , scriptOpToInt
  , SigHash(..)
  , txSigHash
  , encodeSigHash32
  , isSigAll
  , isSigNone
  , isSigSingle
  , isSigUnknown
  , TxSignature(..)
  , encodeSig
  , decodeSig
  , decodeCanonicalSig
  , evalScript
  , verifySpend
  , SigCheck
  ) where

-- *Scripts
-- | More informations on scripts is available here:
-- <http://en.bitcoin.it/wiki/Script>
-- *SigHash
-- | For additional information on sighashes, see:
-- <http://en.bitcoin.it/wiki/OP_CHECKSIG>
-- *Evaluation
import           Network.Haskoin.Script.Evaluator
import           Network.Haskoin.Script.Parser
import           Network.Haskoin.Script.SigHash
import           Network.Haskoin.Script.Types
