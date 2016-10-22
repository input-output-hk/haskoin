{-# LANGUAGE TemplateHaskell #-}

module Network.Haskoin.Wallet.Client
       ( clientMain
       ) where

import           System.Console.GetOpt                  (ArgDescr (NoArg, ReqArg),
                                                         ArgOrder (Permute),
                                                         OptDescr (Option),
                                                         getOpt, usageInfo)
import           System.Directory                       (createDirectoryIfMissing)
import           System.Environment                     (getArgs, lookupEnv)
import           System.FilePath                        ((</>))
import           System.Info                            (os)
import           System.Posix.Directory                 (changeWorkingDirectory)
import           System.Posix.Files                     (fileExist, groupModes,
                                                         otherModes, ownerModes,
                                                         setFileCreationMask,
                                                         setFileMode,
                                                         unionFileModes)

import           Control.Monad                          (forM_, when)
import qualified Control.Monad.Reader                   as R (runReaderT)
import           Control.Monad.Trans                    (liftIO)

import           Data.Default                           (def)
import           Data.FileEmbed                         (embedFile)
import           Data.String.Conversions                (cs)
import           Data.Yaml                              (decodeFileEither)

import           Network.Haskoin.Constants              (networkName,
                                                         switchToTestnet3)
import           Network.Haskoin.Crypto                 (parseHard)
import qualified Network.Haskoin.Wallet.Client.Commands as CMD
import           Network.Haskoin.Wallet.Settings        (Config (..),
                                                         OutputFormat (..))
import           Network.Haskoin.Wallet.Types           (AddressType (..))

import           System.Exit                            (exitFailure)
import           System.FilePath.Posix                  (isAbsolute)
import           System.IO                              (hPutStrLn, stderr)

usageHeader :: String
usageHeader = "Usage: hw [<options>] <command> [<args>]"

cmdHelp :: [String]
cmdHelp = lines $ cs $ $(embedFile "config/help")

warningMsg :: String
warningMsg =
    unwords
        [ "!!!"
        , "This software is experimental."
        , "Use only small amounts of Bitcoins."
        , "!!!"
        ]

usage :: [String]
usage = warningMsg : usageInfo usageHeader options : cmdHelp

read'
    :: Read x
    => String -> String -> x
read' e s =
    case reads s of
        [(x, "")] -> x
        _         -> error e

options :: [OptDescr (Config -> Config)]
options =
    [ Option
          "c"
          ["count"]
          (ReqArg
               (\s cfg ->
                     cfg
                     { configCount = read' "Could not parse count" s
                     })
               "INT") $
      "Items per page. Default: " ++ show (configCount def)
    , Option
          "m"
          ["minconf"]
          (ReqArg
               (\s cfg ->
                     cfg
                     { configMinConf = read' "Colud not parse minconf" s
                     })
               "INT") $
      "Minimum confirmations. Default: " ++ show (configMinConf def)
    , Option
          "f"
          ["fee"]
          (ReqArg
               (\s cfg ->
                     cfg
                     { configFee = read' "Could not parse fee" s
                     })
               "INT") $
      "Fee per kilobyte. Default: " ++ show (configFee def)
    , Option
          "R"
          ["rcptfee"]
          (NoArg $
           \cfg ->
                cfg
                { configRcptFee = True
                }) $
      "Recipient pays fee. Default: " ++ show (configRcptFee def)
    , Option
          "S"
          ["nosig"]
          (NoArg $
           \cfg ->
                cfg
                { configSignTx = False
                }) $
      "Do not sign. Default: " ++ show (not $ configSignTx def)
    , Option
          "i"
          ["internal"]
          (NoArg $
           \cfg ->
                cfg
                { configAddrType = AddressInternal
                }) $
      "Internal addresses. Default: " ++
      show (configAddrType def == AddressInternal)
    , Option
          "o"
          ["offline"]
          (NoArg $
           \cfg ->
                cfg
                { configOffline = True
                }) $
      "Offline balance. Default: " ++ show (configOffline def)
    , Option
          "r"
          ["revpage"]
          (NoArg $
           \cfg ->
                cfg
                { configReversePaging = True
                }) $
      "Reverse paging. Default: " ++ show (configReversePaging def)
    , Option
          "p"
          ["path"]
          (ReqArg
               (\s cfg ->
                     case parseHard s of
                         Just p ->
                             cfg
                             { configPath = Just p
                             }
                         Nothing -> error "Could not parse derivation path")
               "PATH")
          "Derivation path (e.g. m/44'/3')"
    , Option
          "j"
          ["json"]
          (NoArg $
           \cfg ->
                cfg
                { configFormat = OutputJSON
                })
          "Output JSON"
    , Option
          "y"
          ["yaml"]
          (NoArg $
           \cfg ->
                cfg
                { configFormat = OutputYAML
                })
          "Output YAML"
    , Option
          "s"
          ["socket"]
          (ReqArg
               (\s cfg ->
                     cfg
                     { configConnect = s
                     })
               "URI") $
      "Server socket. Default: " ++ configConnect def
    , Option
          "d"
          ["detach"]
          (NoArg $
           \cfg ->
                cfg
                { configDetach = True
                }) $
      "Detach server. Default: " ++ show (configDetach def)
    , Option
          "t"
          ["testnet"]
          (NoArg $
           \cfg ->
                cfg
                { configTestnet = True
                })
          "Testnet3 network"
    , Option
          "g"
          ["config"]
          (ReqArg
               (\s cfg ->
                     cfg
                     { configFile = s
                     })
               "FILE") $
      "Config file. Default: " ++ configFile def
    , Option
          "w"
          ["workdir"]
          (ReqArg
               (\s cfg ->
                     cfg
                     { configDir = s
                     })
               "DIR")
          "Working directory. OS-dependent default"
    , Option
          "v"
          ["verbose"]
          (NoArg $
           \cfg ->
                cfg
                { configVerbose = True
                })
          "Verbose output"
    ]

-- Create and change current working directory
setWorkDir :: Config -> IO ()
setWorkDir cfg = do
    let workDir = configDir cfg </> networkName
    _ <- setFileCreationMask $ otherModes `unionFileModes` groupModes
    createDirectoryIfMissing True workDir
    setFileMode workDir ownerModes
    changeWorkingDirectory workDir

-- Build application configuration
getConfig :: [Config -> Config] -> IO Config
getConfig fs
          -- Create initial configuration from defaults and command-line arguments
 = do
    let initCfg = foldr ($) def fs
    -- If working directory set in initial configuration, use it
    dir <-
        case configDir initCfg of
            "" -> appDir
            d  -> return d
    -- Make configuration file relative to working directory
    let cfgFile =
            if isAbsolute (configFile initCfg)
                then configFile initCfg
                else dir </> configFile initCfg
    -- Get configuration from file, if it exists
    e <- fileExist cfgFile
    if e
        then do
            cfgE <- decodeFileEither cfgFile
            case cfgE of
                Left x    -> error $ show x
                -- Override settings from file using command-line
                Right cfg -> return $ fixConfigDir (foldr ($) cfg fs) dir
        else return $ fixConfigDir initCfg dir
  where
    fixConfigDir cfg dir =
        case configDir cfg of
            "" ->
                cfg
                { configDir = dir
                }
            _ -> cfg

-- If working directory not set, use default
clientMain :: IO ()
clientMain =
    getArgs >>=
    \args ->
         case getOpt Permute options args of
             (fs, commands, []) -> do
                 cfg <- getConfig fs
                 when (configTestnet cfg) switchToTestnet3
                 setWorkDir cfg
                 dispatchCommand cfg commands
             (_, _, msgs) -> forM_ (msgs ++ usage) putStrLn

dispatchCommand :: Config -> [String] -> IO ()
dispatchCommand cfg args =
    flip R.runReaderT cfg $
    case args of
        "start":[] -> CMD.cmdStart
        "stop":[] -> CMD.cmdStop
        "newacc":name:[] -> CMD.cmdNewAcc False name []
        "newread":name:[] -> CMD.cmdNewAcc True name []
        "newms":name:m:n:[] -> CMD.cmdNewAcc False name [m, n]
        "newreadms":name:m:n:[] -> CMD.cmdNewAcc True name [m, n]
        "addkey":name:[] -> CMD.cmdAddKey name
        "setgap":name:gap:[] -> CMD.cmdSetGap name gap
        "account":name:[] -> CMD.cmdAccount name
        "accounts":page -> CMD.cmdAccounts page
        "rename":name:new:[] -> CMD.cmdRenameAcc name new
        "list":name:page -> CMD.cmdList name page
        "unused":name:page -> CMD.cmdUnused name page
        "label":name:index:label:[] -> CMD.cmdLabel name index label
        "txs":name:page -> CMD.cmdTxs name page
        "addrtxs":name:index:page -> CMD.cmdAddrTxs name index page
        "genaddrs":name:i:[] -> CMD.cmdGenAddrs name i
        "send":name:add:amnt:[] -> CMD.cmdSend name add amnt
        "sendmany":name:xs -> CMD.cmdSendMany name xs
        "import":name:[] -> CMD.cmdImport name
        "sign":name:txid:[] -> CMD.cmdSign name txid
        "gettx":name:txid:[] -> CMD.cmdGetTx name txid
        "balance":name:[] -> CMD.cmdBalance name
        "getoffline":name:txid:[] -> CMD.cmdGetOffline name txid
        "signoffline":name:tx:dat:[] -> CMD.cmdSignOffline name tx dat
        "rescan":rescantime -> CMD.cmdRescan rescantime
        "deletetx":txid:[] -> CMD.cmdDeleteTx txid
        "sync":name:block:page -> CMD.cmdSync name block page
        "pending":name:page -> CMD.cmdPending name page
        "dead":name:page -> CMD.cmdDead name page
        "monitor":name -> CMD.cmdMonitor name
        "decodetx":[] -> CMD.cmdDecodeTx
        "status":[] -> CMD.cmdStatus
        "keypair":[] -> CMD.cmdKeyPair
        "version":[] -> CMD.cmdVersion
        "help":[] -> liftIO $ forM_ usage (hPutStrLn stderr)
        [] -> liftIO $ forM_ usage (hPutStrLn stderr)
        _ -> liftIO $ forM_ ("Invalid command" : usage) (hPutStrLn stderr) >> exitFailure

appDir :: IO FilePath
appDir =
    case os of
        "mingw"   -> windows
        "mingw32" -> windows
        "mingw64" -> windows
        "darwin"  -> osx
        "linux"   -> unix
        _         -> unix
  where
    windows = do
        localAppData <- lookupEnv "LOCALAPPDATA"
        dirM <-
            case localAppData of
                Nothing -> lookupEnv "APPDATA"
                Just l  -> return $ Just l
        case dirM of
            Just d  -> return $ d </> "Haskoin Wallet"
            Nothing -> return "."
    osx = do
        homeM <- lookupEnv "HOME"
        case homeM of
            Just home ->
                return $
                home </> "Library" </> "Application Support" </>
                "Haskoin Wallet"
            Nothing -> return "."
    unix = do
        homeM <- lookupEnv "HOME"
        case homeM of
            Just home -> return $ home </> ".hw"
            Nothing   -> return "."
