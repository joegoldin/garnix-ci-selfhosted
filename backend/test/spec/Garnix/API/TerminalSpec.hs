{-# LANGUAGE OverloadedRecordDot #-}

-- | The security gate of the web terminal (/api/terminal/<serverId>):
-- unauthenticated or unowned connections must be rejected before anything is
-- spawned, cross-origin browser requests must be refused, and an owned +
-- online server must be reachable over a real websocket upgrade.
module Garnix.API.TerminalSpec (spec) where

import Control.Exception.Safe qualified as Safe
import Data.Char (isDigit)
import Data.Text qualified as T
import Garnix.DB qualified as DB
import Garnix.GithubInterface.Types
import Garnix.Monad
import Garnix.Prelude
import Garnix.TestHelpers
import Garnix.TestHelpers.Monad
import Garnix.TestHelpers.WithServer
import Garnix.Types
import Network.WebSockets qualified as WS
import Servant.Auth.Server (makeJWT)
import System.Timeout (timeout)
import Test.Hspec hiding (shouldReturn)

spec :: Spec
spec = do
  inM $ beforeM_ truncateDBM $ aroundM_ suppressLogsWhenPassing $ do
    describe "/api/terminal" $ do
      it "responds with 401 when logged out" $ withServer $ \testServer -> do
        result <- testServer.get "/api/terminal/vBV73Z9e"
        result `shouldHaveStatusCode` 401

      it "responds with 404 for an unknown server id" $ withServer $ \testServer -> do
        _user <- testServer.login
        result <- testServer.get "/api/terminal/vBV73Z9e"
        result `shouldHaveStatusCode` 404

      it "responds with 404 for a server owned by someone else" $ withServer $ \testServer -> do
        user <- testServer.login
        server <-
          createServer
            (GhRepoOwner (GhLogin "some-other-owner"))
            (GhRepoName "repo")
            (Branch "branch")
            (PackageName "package")
            user
            (ipv4Addr .~ "10.0.0.1")
        result <- testServer.get (terminalPath server)
        result `shouldHaveStatusCode` 404

      it "responds with 404 for an owned server that is not online" $ withServer $ \testServer -> do
        user <- testServer.login
        server <- createSimpleServer user (ipv4Addr .~ "10.0.0.1")
        markServerDead server
        result <- testServer.get (terminalPath server)
        result `shouldHaveStatusCode` 404

      it "responds with 404 for an owned server without a usable guest address" $ withServer $ \testServer -> do
        user <- testServer.login
        server <- createSimpleServer user identity
        result <- testServer.get (terminalPath server)
        result `shouldHaveStatusCode` 404

      it "responds with 403 for a mismatched browser Origin" $ withServer $ \testServer -> do
        user <- testServer.login
        server <- createSimpleServer user (ipv4Addr .~ "10.0.0.1")
        result <-
          testServer.getWithHeaders
            (terminalPath server)
            [("Origin", "https://evil.example")]
        result `shouldHaveStatusCode` 403

      it "responds with 426 for an owned online server on a plain http request" $ withServer $ \testServer -> do
        user <- testServer.login
        server <- createSimpleServer user (ipv4Addr .~ "10.0.0.1")
        result <- testServer.get (terminalPath server)
        result `shouldHaveStatusCode` 426

      it "responds with 426 when the Origin matches the app origin" $ withServer $ \testServer -> do
        user <- testServer.login
        server <- createSimpleServer user (ipv4Addr .~ "10.0.0.1")
        appOrigin <- view #baseUrl
        result <-
          testServer.getWithHeaders
            (terminalPath server)
            [("Origin", cs appOrigin)]
        result `shouldHaveStatusCode` 426

      it "upgrades an authenticated owned connection and closes when the shell exits" $ withServer $ \testServer -> do
        user <- testServer.login
        -- Point the "guest" at a closed local port: ssh fails immediately, the
        -- PTY hits EOF, and the server must close the websocket cleanly.
        server <- createSimpleServer user (ipv4Addr .~ "127.0.0.1:1")
        jwtSettings' <- view #jwtSettings
        jwt <-
          liftIO (makeJWT (WebSession user (GhToken "tok")) jwtSettings' Nothing) >>= \case
            Left err -> liftIO $ Safe.throwString ("makeJWT failed: " <> show err)
            Right jwt -> pure jwt
        let port :: Int
            port = read $ cs $ T.takeWhile isDigit $ T.drop (T.length "http://localhost:") (apiUrl testServer)
        closeReason <- liftIO $ timeout (30 * 1000000) $ do
          WS.runClientWith
            "127.0.0.1"
            port
            (terminalPath server)
            WS.defaultConnectionOptions
            [("Authorization", "Bearer " <> cs jwt)]
            $ \conn ->
              let drainUntilClose =
                    (WS.receiveDataMessage conn >> drainUntilClose)
                      `catch` \case
                        WS.CloseRequest _ reason -> pure (cs reason :: Text)
                        other -> Safe.throwIO other
               in drainUntilClose
        closeReason `shouldBeM` Just "shell exited"

terminalPath :: ServerInfo -> String
terminalPath server = cs ("/api/terminal/" <> getHashId (getServerId (server ^. id)))

createSimpleServer :: User -> (ServerInfo -> ServerInfo) -> M ServerInfo
createSimpleServer user =
  createServer
    (GhRepoOwner $ user ^. githubLogin)
    (GhRepoName "repo")
    (Branch "branch")
    (PackageName "package")
    user

createServer :: GhRepoOwner -> GhRepoName -> Branch -> PackageName -> User -> (ServerInfo -> ServerInfo) -> M ServerInfo
createServer repoOwner repoName branch packageName user updateServerInfo = do
  let commitInfo =
        CommitInfo
          (user ^. githubLogin)
          (RepoIsPublic True)
          (RepoInfo ForgeGithub Nothing undefined repoOwner repoName)
          (Just branch)
          Nothing
          (CommitHash "baz")
  build <-
    DB.newBuildDB
      commitInfo
      (PackageInfo TypePackage (IsSystem X8664Linux) packageName)
      "garnix-server-test"
      False
  DB.reportBuildResultDB build
  now <- liftIO getCurrentTime
  addTestServer $ updateServerInfo . \server ->
    server
      & configurationBuildId .~ (build ^. id)
      & readyAt ?~ now

markServerDead :: ServerInfo -> M ()
markServerDead serverInfo = do
  now <- liftIO getCurrentTime
  DB.updateServerPostDeploy $ serverInfo & endedAt ?~ now
