module Network.Haskoin.Index.Client (clientMain) where

import System.FilePath ((</>))
import System.Directory (createDirectoryIfMissing)
import System.Posix.Directory (changeWorkingDirectory)
import System.Posix.Files
    ( setFileMode
    , setFileCreationMask
    , unionFileModes
    , ownerModes
    , groupModes
    , otherModes
    , fileExist
    )
import System.Environment (getArgs, lookupEnv)
import System.Info (os)
import System.Console.GetOpt
    ( getOpt
    , usageInfo
    , OptDescr (Option)
    , ArgDescr (NoArg, ReqArg)
    , ArgOrder (Permute)
    )

import Control.Monad (when, forM_)
import Control.Monad.Trans (liftIO)
import qualified Control.Monad.Reader as R (runReaderT)

import Data.Default (def)
import Data.FileEmbed (embedFile)
import Data.Yaml (decodeFileEither)
import Data.String.Conversions (cs)

import Network.Haskoin.Constants
import Network.Haskoin.Index.Settings
import Network.Haskoin.Index.Client.Commands

import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.FilePath.Posix (isAbsolute)

usageHeader :: String
usageHeader = "Usage: haskoin-index [<options>] <command> [<args>]"

cmdHelp :: [String]
cmdHelp = lines $ cs $ $(embedFile "config/help")

warningMsg :: String
warningMsg = unwords
    [ "!!!", "This software is experimental."
    , "Use only small amounts of Bitcoins.", "!!!"
    ]

usage :: [String]
usage = warningMsg : usageInfo usageHeader options : cmdHelp

options :: [OptDescr (Config -> Config)]
options =
    [ Option "d" ["detach"]
        (NoArg $ \cfg -> cfg { configDetach = True }) $
        "Detach server. Default: " ++ show (configDetach def)
    , Option "t" ["testnet"]
        (NoArg $ \cfg -> cfg { configTestnet = True }) "Testnet3 network"
    , Option "g" ["config"]
        (ReqArg (\s cfg -> cfg { configFile = s }) "FILE") $
        "Config file. Default: " ++ configFile def
    , Option "w" ["workdir"]
        (ReqArg (\s cfg -> cfg { configDir = s }) "DIR")
        "Working directory. OS-dependent default"
    ]

clientMain :: IO ()
clientMain = getArgs >>= \args -> case getOpt Permute options args of
    (fs, commands, []) -> do
        cfg <- getConfig fs
        when (configTestnet cfg) switchToTestnet3
        setWorkDir cfg
        dispatchCommand cfg commands
    (_, _, msgs) -> forM_ (msgs ++ usage) putStrLn

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
getConfig fs = do
    -- Create initial configuration from defaults and command-line arguments
    let initCfg = foldr ($) def fs

    -- If working directory set in initial configuration, use it
    dir <- case configDir initCfg of "" -> appDir
                                     d  -> return d

    -- Make configuration file relative to working directory
    let cfgFile = if isAbsolute (configFile initCfg)
                     then configFile initCfg
                     else dir </> configFile initCfg

    -- Get configuration from file, if it exists
    e <- fileExist cfgFile
    if e then do
            cfgE <- decodeFileEither cfgFile
            case cfgE of
                Left x -> error $ show x
                -- Override settings from file using command-line
                Right cfg -> return $ fixConfigDir (foldr ($) cfg fs) dir
         else return $ fixConfigDir initCfg dir
  where
    -- If working directory not set, use default
    fixConfigDir cfg dir = case configDir cfg of "" -> cfg{ configDir = dir }
                                                 _  -> cfg

dispatchCommand :: Config -> [String] -> IO ()
dispatchCommand cfg args = flip R.runReaderT cfg $ case args of
    "start"    : []              -> cmdStart
    "stop"     : []              -> cmdStop
    "status"   : []              -> cmdStatus
    "addrtxs"  : addr : []       -> cmdAddressTxs addr
    "optxs"    : hash : pos : [] -> cmdOutpointTxs hash pos
    "version"  : []              -> cmdVersion
    "help"     : []              -> liftIO $ forM_ usage (hPutStrLn stderr)
    []                           -> liftIO $ forM_ usage (hPutStrLn stderr)
    _ -> liftIO $
        forM_ ("Invalid command" : usage) (hPutStrLn stderr) >> exitFailure

appDir :: IO FilePath
appDir = case os of "mingw"   -> windows
                    "mingw32" -> windows
                    "mingw64" -> windows
                    "darwin"  -> osx
                    "linux"   -> unix
                    _         -> unix
  where
    windows = do
        localAppData <- lookupEnv "LOCALAPPDATA"
        dirM <- case localAppData of
            Nothing -> lookupEnv "APPDATA"
            Just l -> return $ Just l
        case dirM of
            Just d -> return $ d </> "Haskoin Index"
            Nothing -> return "."
    osx = do
        homeM <- lookupEnv "HOME"
        case homeM of
            Just home -> return $ home </> "Library"
                                       </> "Application Support"
                                       </> "Haskoin Index"
            Nothing -> return "."
    unix = do
        homeM <- lookupEnv "HOME"
        case homeM of
            Just home -> return $ home </> ".haskoin-index"
            Nothing -> return "."

