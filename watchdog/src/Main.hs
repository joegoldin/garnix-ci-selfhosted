module Main where

import Control.Concurrent.Async
import Control.Lens
import Control.Monad
import qualified Data.Map as Map
import Data.String.Conversions
import qualified Data.Text.IO as T
import Garnix.Watchdog.Checks
import Garnix.Watchdog.Utils
import Network.Wai.Handler.Warp hiding (run)
import Network.Wai.Middleware.RequestLogger (logStdout)
import System.Environment (getEnv)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stderr)
import System.Metrics.Prometheus.Concurrent.Registry
import qualified System.Metrics.Prometheus.Http.Scrape as Prom
import Text.Read (readMaybe)
import WithCli
import Prelude hiding (log)

data CliOptions = CliOptions
  { noDaemon :: Bool,
    runCheck :: [String]
  }
  deriving stock (Show, Generic)
  deriving anyclass (HasArguments)

main :: IO ()
main = withCli $ \cliOptions -> do
  hSetBuffering stderr LineBuffering
  dataDir <- getEnv "DATA_DIR"
  sshIdentityFile <- getEnv "WATCHDOG_SSH_IDENTITY_FILE"
  let config = CheckConfig {dataDir, sshIdentityFile}
      eChecks = case cliOptions.runCheck of
        [] -> Right $ Map.elems defaultChecks
        names -> forM names $ \name ->
          case Map.lookup (CheckName $ cs name) allChecks of
            Nothing ->
              Left $
                "cannot find check: "
                  <> name
                  <> " possible options: "
                  <> show (map getCheckName (Map.keys allChecks))
            Just check -> Right check
  checks <- either abort pure eChecks
  if noDaemon cliOptions
    then forConcurrently_ checks $ \check -> do
      result <- Garnix.Watchdog.Checks.runCheck config check
      log check.name $ cs $ show result
    else do
      port <- maybe (abort "PORT env var parse error") pure . readMaybe =<< getEnv "PORT"
      runDaemon port config checks

runDaemon :: Port -> CheckConfig -> [Check] -> IO ()
runDaemon port config checks = do
  registry <- new
  runChecksAsMetrics config registry checks
  serveMetrics port registry

serveMetrics :: Port -> Registry -> IO ()
serveMetrics port registry = do
  let settings =
        defaultSettings
          & setPort port
          & setHost "127.0.0.1"
          & setBeforeMainLoop (T.hPutStrLn stderr $ "listening on port " <> cs (show port))
  runSettings settings $
    logStdout $
      Prom.prometheusApp [] $
        sample registry
