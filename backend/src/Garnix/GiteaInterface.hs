-- | REST client for a self-hosted Gitea instance, mirroring the subset of
-- 'Garnix.GithubInterface' that the CI build path needs. Gitea has no
-- GitHub-App-style installations: every call authenticates with the single
-- configured bot/admin token (@Authorization: token <t>@, which is exactly what
-- 'Wreq.oauth2Token' produces).
--
-- These are plain functions (not wired into the 'GithubInterface' record) —
-- the forge-dispatch call sites choose between the GitHub and Gitea
-- implementations by 'Forge'.
module Garnix.GiteaInterface
  ( requireGiteaConfig,
    giteaGetRepoPublicity,
    giteaGetRepoCollaborators,
    giteaGetRemote,
    GiteaStatusState (..),
    GiteaCommitStatus (..),
    giteaPostCommitStatus,
  )
where

import Control.Lens hiding ((.=))
import Data.Aeson (object, (.=))
import Data.Aeson.Lens (key, values, _Bool, _String)
import Data.Text qualified as T
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import Network.Wreq qualified as Wreq

-- | The configured Gitea instance, or a clear error if a Gitea code path was
-- reached without @GITEA_URL@ set (should not happen — the webhook route is
-- only mounted when Gitea is configured).
requireGiteaConfig :: (HasCallStack) => M GiteaConfig
requireGiteaConfig =
  view #giteaConfig
    >>= maybe (throw $ OtherError "Gitea forge used but no Gitea instance is configured (set GITEA_URL)") pure

-- | Apply the Gitea bearer token + disable wreq's throw-on-non-2xx (we inspect
-- the status ourselves).
giteaOptions :: GiteaConfig -> Wreq.Options -> Wreq.Options
giteaOptions cfg opts =
  opts
    & Wreq.auth
    ?~ Wreq.oauth2Token (cs (_giteaConfigApiToken cfg))
    & Wreq.checkResponse
    ?~ \_ _ -> pure ()

giteaRepoUrl :: GiteaConfig -> GhRepoOwner -> GhRepoName -> Text
giteaRepoUrl cfg (GhRepoOwner (GhLogin owner)) (GhRepoName repo) =
  _giteaConfigBaseUrl cfg <> "/api/v1/repos/" <> owner <> "/" <> repo

assertGiteaOk :: (HasCallStack) => Text -> Wreq.Response body -> M ()
assertGiteaOk ctx resp =
  when (resp ^. Wreq.responseStatus . Wreq.statusCode >= 400)
    $ throw
    $ OtherError
    $ ctx <> ": gitea returned status " <> show (resp ^. Wreq.responseStatus . Wreq.statusCode)

-- | @GET /api/v1/repos/{owner}/{repo}@ → @.private@.
giteaGetRepoPublicity :: (HasCallStack) => GiteaConfig -> GhRepoOwner -> GhRepoName -> M RepoPublicity
giteaGetRepoPublicity cfg owner repo = do
  resp <- withWreqOptions $ \opts -> Wreq.getWith (giteaOptions cfg opts) (cs (giteaRepoUrl cfg owner repo))
  assertGiteaOk "giteaGetRepoPublicity" resp
  let priv = resp ^? Wreq.responseBody . key "private" . _Bool
  pure $ RepoIsPublic (not (fromMaybe False priv))

-- | @GET /api/v1/repos/{owner}/{repo}/collaborators@ → each @.login@.
giteaGetRepoCollaborators :: (HasCallStack) => GiteaConfig -> GhRepoOwner -> GhRepoName -> M GhCollaborators
giteaGetRepoCollaborators cfg owner repo = do
  resp <- withWreqOptions $ \opts -> Wreq.getWith (giteaOptions cfg opts) (cs (giteaRepoUrl cfg owner repo <> "/collaborators"))
  assertGiteaOk "giteaGetRepoCollaborators" resp
  let logins = resp ^.. Wreq.responseBody . values . key "login" . _String
  pure $ GhCollaborators (GhLogin <$> logins)

-- | Tokenized clone URL: @https://<token>@<host>/<owner>/<repo>.git@.
giteaGetRemote :: GiteaConfig -> GhRepoOwner -> GhRepoName -> RemoteUrl
giteaGetRemote cfg (GhRepoOwner (GhLogin owner)) (GhRepoName repo) =
  let host = T.replace "http://" "" (T.replace "https://" "" (_giteaConfigBaseUrl cfg))
   in RemoteUrl
        $ "https://"
        <> _giteaConfigApiToken cfg
        <> "@"
        <> host
        <> "/"
        <> owner
        <> "/"
        <> repo
        <> ".git"

data GiteaStatusState = GiteaPending | GiteaSuccess | GiteaError | GiteaFailure
  deriving stock (Eq, Show)

giteaStateText :: GiteaStatusState -> Text
giteaStateText = \case
  GiteaPending -> "pending"
  GiteaSuccess -> "success"
  GiteaError -> "error"
  GiteaFailure -> "failure"

data GiteaCommitStatus = GiteaCommitStatus
  { giteaStatusState :: GiteaStatusState,
    giteaStatusTargetUrl :: Text,
    giteaStatusDescription :: Text,
    giteaStatusContext :: Text
  }

-- | @POST /api/v1/repos/{owner}/{repo}/statuses/{sha}@ — Gitea's commit-status
-- API (the cross-forge equivalent of GitHub check-runs).
giteaPostCommitStatus :: (HasCallStack) => GiteaConfig -> GhRepoOwner -> GhRepoName -> CommitHash -> GiteaCommitStatus -> M ()
giteaPostCommitStatus cfg owner repo (CommitHash sha) st = do
  let url = giteaRepoUrl cfg owner repo <> "/statuses/" <> sha
      body =
        object
          [ "state" .= giteaStateText (giteaStatusState st),
            "target_url" .= giteaStatusTargetUrl st,
            -- Gitea caps description length; keep it short.
            "description" .= T.take 255 (giteaStatusDescription st),
            "context" .= giteaStatusContext st
          ]
  resp <- withWreqOptions $ \opts -> Wreq.postWith (giteaOptions cfg opts) (cs url) body
  assertGiteaOk "giteaPostCommitStatus" resp
