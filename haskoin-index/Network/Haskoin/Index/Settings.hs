module Network.Haskoin.Index.Settings
( Config(..)
, OutputFormat(..)
, BTCNode(..)
) where

import           Control.Exception              (throw)
import           Control.Monad                  (mzero)
import           Control.Monad.Logger           (LogLevel (..))
import           Data.Aeson                     (FromJSON, ToJSON, Value (..),
                                                 object, parseJSON, toJSON,
                                                 withObject, (.:), (.=))
import           Data.ByteString                (ByteString)
import           Data.Default                   (Default, def)
import           Data.FileEmbed                 (embedFile)
import           Data.HashMap.Strict            (HashMap, unionWith)
import           Data.Restricted                (Div5, Restricted)
import           Data.String.Conversions        (cs)
import           Data.Text                      (Text)
import           Data.Text.Encoding             (encodeUtf8)
import           Data.Yaml                      (decodeEither')
import           Network.Haskoin.Index.Database
import           System.ZMQ4                    (toRestricted)

newtype LogLevelJSON = LogLevelJSON LogLevel
    deriving (Eq, Show, Read)

data BTCNode = BTCNode { btcNodeHost :: !String, btcNodePort :: !Int }
    deriving (Eq, Read, Show)

data OutputFormat
    = OutputNormal
    | OutputJSON
    | OutputYAML

data Config = Config
    { configBind          :: !String
    -- ^ Bind address for the ZeroMQ socket
    , configBindNotif     :: !String
    -- ^ Bind address for ZeroMQ notifications
    , configDatabase      :: !(HashMap Text DatabaseConfType)
    -- ^ Database configuration
    , configLevelDBParams :: !(HashMap Text Int)
    -- ^ Address index parameters
    , configBTCNodes      :: !(HashMap Text [BTCNode])
    -- ^ Trusted Bitcoin full nodes to connect to
    , configLogFile       :: !FilePath
    -- ^ Log file
    , configLogLevel      :: !LogLevel
    -- ^ Log level
    , configPidFile       :: !FilePath
    -- ^ PID File
    , configDir           :: !FilePath
    -- ^ Working directory
    , configFile          :: !FilePath
    -- ^ Configuration file
    , configDetach        :: !Bool
    -- ^ Detach the indexing process
    , configTestnet       :: !Bool
    -- ^ Use Testnet3 network
    , configFormat        :: !OutputFormat
    -- ^ How to format the command-line results
    , configServerKey     :: !(Maybe (Restricted Div5 ByteString))
    -- ^ Server key for authentication and encryption (server config)
    , configServerKeyPub  :: !(Maybe (Restricted Div5 ByteString))
    -- ^ Server public key for authentication and encryption (client config)
    , configClientKey     :: !(Maybe (Restricted Div5 ByteString))
    -- ^ Client key for authentication and encryption (client config)
    , configClientKeyPub  :: !(Maybe (Restricted Div5 ByteString))
    -- ^ Client public key for authentication and encryption
    -- (client + server config)
    }

configBS :: ByteString
configBS = $(embedFile "config/config.yml")

instance ToJSON BTCNode where
    toJSON (BTCNode h p) = object [ "host" .= h, "port" .= p ]

instance FromJSON BTCNode where
    parseJSON = withObject "BTCNode" $ \o -> do
        btcNodeHost <- o .: "host"
        btcNodePort <- o .: "port"
        return BTCNode {..}

instance ToJSON OutputFormat where
    toJSON OutputNormal = String "normal"
    toJSON OutputJSON   = String "json"
    toJSON OutputYAML   = String "yaml"

instance FromJSON OutputFormat where
    parseJSON (String "normal") = return OutputNormal
    parseJSON (String "json")   = return OutputJSON
    parseJSON (String "yaml")   = return OutputYAML
    parseJSON _ = mzero

instance ToJSON LogLevelJSON where
    toJSON (LogLevelJSON LevelDebug)     = String "debug"
    toJSON (LogLevelJSON LevelInfo)      = String "info"
    toJSON (LogLevelJSON LevelWarn)      = String "warn"
    toJSON (LogLevelJSON LevelError)     = String "error"
    toJSON (LogLevelJSON (LevelOther t)) = String t

instance FromJSON LogLevelJSON where
    parseJSON (String "debug") = return $ LogLevelJSON LevelDebug
    parseJSON (String "info")  = return $ LogLevelJSON LevelInfo
    parseJSON (String "warn")  = return $ LogLevelJSON LevelWarn
    parseJSON (String "error") = return $ LogLevelJSON LevelError
    parseJSON (String x)       = return $ LogLevelJSON (LevelOther x)
    parseJSON _ = mzero

instance Default Config where
    def = either throw id $ decodeEither' "{}"

instance FromJSON Config where
    parseJSON = withObject "config" $ \o' -> do
        let defValue         = either throw id $ decodeEither' configBS
            (Object o)       = mergeValues defValue (Object o')
        configBind                  <- o .: "bind-socket"
        configBindNotif             <- o .: "bind-socket-notif"
        configDatabase              <- o .: "database"
        configLevelDBParams         <- o .: "leveldb-params"
        configBTCNodes              <- o .: "bitcoin-full-nodes"
        configLogFile               <- o .: "log-file"
        LogLevelJSON configLogLevel <- o .: "log-level"
        configPidFile               <- o .: "pid-file"
        configDir                   <- o .: "work-dir"
        configFile                  <- o .: "config-file"
        configDetach                <- o .: "detach-server"
        configTestnet               <- o .: "use-testnet"
        configFormat                <- o .: "display-format"
        configServerKey             <- getKey o "server-key"
        configServerKeyPub          <- getKey o "server-key-public"
        configClientKey             <- getKey o "client-key"
        configClientKeyPub          <- getKey o "client-key-public"
        return Config {..}
      where
        getKey o i = o .: i >>= \kM ->
            case kM of
              Nothing -> return Nothing
              Just k ->
                  case toRestricted $ encodeUtf8 k of
                    Just k' -> return $ Just k'
                    Nothing -> fail $ "Invalid " ++ cs k


mergeValues :: Value -> Value -> Value
mergeValues (Object d) (Object c) = Object (unionWith mergeValues d c)
mergeValues _ c = c

