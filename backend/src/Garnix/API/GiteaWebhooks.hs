{-# LANGUAGE TypeFamilies #-}

-- | Inbound webhook handling for a self-hosted Gitea instance. Mirrors the
-- GitHub push path (@Garnix.API.GhWebhooks@) but for Gitea: verify the
-- @X-Gitea-Signature@ HMAC-SHA256 over the raw body, parse Gitea's push
-- payload, and hand the resulting 'CommitInfo' to the shared build pipeline
-- ('handleCommit') with a Gitea commit-status reporter.
module Garnix.API.GiteaWebhooks
  ( GiteaWebhookAPI (..),
    giteaWebhookAPI,
  )
where

import Control.Lens
import Crypto.Hash.Algorithms (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Data.Aeson qualified as Aeson
import Data.Aeson.Lens (key, _Bool, _String)
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Garnix.Monad
import Garnix.Orchestrator (handleCommit)
import Garnix.Prelude
import Garnix.Reporters.GiteaReporter (mkGiteaReporter)
import Garnix.Reporters.OpenSearchReporter (openSearchReporter)
import Garnix.Types
import Network.HTTP.Media ((//))
import Servant hiding (Unauthorized)

-- | Raw-body content type: accepts Gitea's @application/json@ webhook but hands
-- us the exact bytes, which the HMAC signature is computed over.
data GiteaRaw

instance Accept GiteaRaw where
  contentType _ = "application" // "json"

instance MimeUnrender GiteaRaw LBS.ByteString where
  mimeUnrender _ = Right

data GiteaWebhookAPI route = GiteaWebhookAPI
  { _giteaWebhookPush ::
      route
        :- Header "X-Gitea-Event" Text
          :> Header "X-Gitea-Signature" Text
          :> ReqBody '[GiteaRaw] LBS.ByteString
          :> Post '[JSON] ()
  }
  deriving (Generic)

giteaWebhookAPI :: GiteaWebhookAPI (AsServerT M)
giteaWebhookAPI = GiteaWebhookAPI {_giteaWebhookPush = handleGiteaWebhook}

handleGiteaWebhook :: (HasCallStack) => Maybe Text -> Maybe Text -> LBS.ByteString -> M ()
handleGiteaWebhook mEvent mSig rawBody =
  view #giteaConfig >>= \case
    Nothing -> pure () -- Gitea not configured; nothing to do.
    Just cfg -> do
      let body = LBS.toStrict rawBody
          expected :: Text
          expected = cs (show (hmacGetDigest (hmac (_giteaConfigWebhookSecret cfg) body :: HMAC SHA256)))
      unless (mSig == Just expected) $ throw Unauthorized
      when (mEvent == Just "push") $ do
        value <-
          either (\e -> throw $ OtherError $ "gitea webhook JSON: " <> cs e) pure
            $ Aeson.eitherDecodeStrict' body
        handleGiteaPush cfg value

handleGiteaPush :: (HasCallStack) => GiteaConfig -> Aeson.Value -> M ()
handleGiteaPush cfg v
  -- Mirror repos are downstream clones (e.g. a Gitea backup mirror of a GitHub
  -- repo synced via Gitea's migration/mirror feature). The upstream forge
  -- already builds these commits, so a mirror-sync push here would
  -- double-trigger garnix — treat the repo as hidden and skip it.
  | isMirror =
      log Notice
        $ "gitea webhook: skipping mirror (downstream clone) repo "
          <> fromMaybe "<unknown>" (v ^? key "repository" . key "full_name" . _String)
  | otherwise =
      case (v ^? key "after" . _String, v ^? key "repository" . key "full_name" . _String) of
        (Just sha, Just fullName)
          | not (T.all (== '0') sha) -> do
              (owner, repo) <- parseFullName fullName
              let private = fromMaybe False (v ^? key "repository" . key "private" . _Bool)
                  reqUser =
                    fromMaybe owner
                      $ (v ^? key "sender" . key "login" . _String)
                      <|> (v ^? key "pusher" . key "login" . _String)
                  branch = (v ^? key "ref" . _String) >>= refToBranch
                  repoInfo' =
                    RepoInfo
                      ForgeGitea
                      Nothing
                      (GhToken (_giteaConfigApiToken cfg))
                      (GhRepoOwner (GhLogin owner))
                      (GhRepoName repo)
                  commitInfo =
                    CommitInfo
                      { _commitInfoReqUser = GhLogin reqUser,
                        _commitInfoRepoPublicity = RepoIsPublic (not private),
                        _commitInfoRepoInfo = repoInfo',
                        _commitInfoBranch = Branch <$> branch,
                        _commitInfoPrFromFork = Nothing,
                        _commitInfoCommit = CommitHash sha
                      }
                  reporter = openSearchReporter <> mkGiteaReporter cfg repoInfo' (CommitHash sha)
              void $ handleCommit reporter False commitInfo
        _ -> pure () -- deleted branch / missing fields: ignore
  where
    isMirror = fromMaybe False (v ^? key "repository" . key "mirror" . _Bool)
    refToBranch r = case T.splitOn "/" r of
      "refs" : "heads" : rest -> Just (T.intercalate "/" rest)
      _ -> Nothing
    parseFullName fn = case T.splitOn "/" fn of
      [o, r] -> pure (o, r)
      _ -> throw $ OtherError $ "gitea webhook: unexpected repository.full_name " <> fn
