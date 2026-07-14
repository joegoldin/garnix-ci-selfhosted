module Garnix.API.Cache.Permissions
  ( Permission (..),
    ServedPathVisibility (..),
    getRepoPermissions,
    __getRepoPermissionsCache,
  )
where

import Garnix.Duration
import Garnix.ExpiringCache
import Garnix.GiteaInterface (giteaGetRepoCollaborators, giteaGetRepoPublicity)
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import GitHub.Data.Id (Id (..))
import System.IO.Unsafe qualified

data Permission
  = Allowed
  | Disallowed
  deriving (Eq, Ord, Show)

-- | Whether the store path being served lives in the public or the private
-- cache bucket. A repo being public on GitHub only implies access to its
-- PUBLIC store paths: a private path from a public repo (self-host mode
-- routes public repos with private flake inputs to the private bucket)
-- must never be served on the strength of the repo's publicity alone.
data ServedPathVisibility = ServingPublicPath | ServingPrivatePath
  deriving (Eq, Ord, Show)

getRepoPermissions :: (HasCallStack) => ServedPathVisibility -> Maybe GhLogin -> GhRepoOwner -> GhRepoName -> M Permission
getRepoPermissions pathVisibility mUser owner repo =
  lookupCache __getRepoPermissionsCache (pathVisibility == ServingPublicPath, mUser, owner, repo)
    $ withTextSpans
      [ ("function", "Garnix.API.Cache.Permissions.getRepoPermission"),
        ("repo_perm_path_visibility", show pathVisibility),
        ("repo_perm_mUser", show mUser),
        ("repo_perm_owner", show owner),
        ("repo_perm_repo", show repo)
      ]
    $ getGarnixInstallationId owner repo
    >>= \case
      Nothing ->
        -- No GitHub installation for this repo. If a Gitea instance is
        -- configured, it may be a Gitea repo — check permissions there so
        -- private Gitea repos serve their cache to authenticated collaborators
        -- (via the same netrc). Otherwise deny.
        view #giteaConfig >>= \case
          Nothing -> do
            log Warning "Cache.getRepoPermissions: could not get garnixInstallationId"
            pure Disallowed
          Just cfg -> giteaRepoPermissions cfg pathVisibility mUser owner repo
      Just id -> do
        log Informational "Cache.getRepoPermissions: got garnixInstallationId"
        iAuth <- getInstallation (Id $ fromInteger id)
        repoPublicity <- try $ getRepoPublicity iAuth owner repo
        log Informational $ "repoPublicity: " <> show repoPublicity
        case (repoPublicity, mUser) of
          (Left err, _) -> do
            log Informational $ "Error fetching repo publicity, disallowing access: " <> show err
            pure Disallowed
          (Right (RepoIsPublic True), _)
            | pathVisibility == ServingPublicPath -> do
                log Informational "repo is public, allowing access"
                pure Allowed
          (_, Nothing) -> do
            log Informational "no authentication claim for a non-public grant"
            pure Disallowed
          (_, Just user) -> do
            collaborators <- getRepoCollaborators iAuth owner repo
            case collaborators of
              RepoNotFound -> do
                log Warning "Repository not found, denying access"
                pure Disallowed
              GhCollaborators collaborators ->
                if user `elem` collaborators
                  then do
                    log Informational "User is a collaborator to the repository, allowing"
                    pure Allowed
                  else do
                    log Notice "Access to disallowed resource. Blocking."
                    pure Disallowed

-- | Gitea equivalent of the GitHub permission check: a private Gitea repo's
-- cache is served only to an authenticated collaborator (by login), matching
-- how private GitHub repos are gated. Public Gitea repos allow public paths.
giteaRepoPermissions :: (HasCallStack) => GiteaConfig -> ServedPathVisibility -> Maybe GhLogin -> GhRepoOwner -> GhRepoName -> M Permission
giteaRepoPermissions cfg pathVisibility mUser owner repo = do
  publicity <- try $ giteaGetRepoPublicity cfg owner repo
  case (publicity, mUser) of
    (Left err, _) -> do
      log Informational $ "Gitea repo publicity fetch failed, denying: " <> show err
      pure Disallowed
    (Right (RepoIsPublic True), _)
      | pathVisibility == ServingPublicPath -> pure Allowed
    (_, Nothing) -> pure Disallowed
    (_, Just user) ->
      try (giteaGetRepoCollaborators cfg owner repo) >>= \case
        Left err -> do
          log Informational $ "Gitea collaborators fetch failed, denying: " <> show err
          pure Disallowed
        Right RepoNotFound -> pure Disallowed
        Right (GhCollaborators collaborators) ->
          pure $ if user `elem` collaborators then Allowed else Disallowed

type GithubPermissionCache = ExpiringCache (Bool, Maybe GhLogin, GhRepoOwner, GhRepoName) Permission

{-# NOINLINE __getRepoPermissionsCache #-}
__getRepoPermissionsCache :: GithubPermissionCache
__getRepoPermissionsCache =
  System.IO.Unsafe.unsafePerformIO
    $ mkCache
      (Just "__getRepoPermissionsCache")
      (fromHours @Int 1)
      (fromMinutes @Int 5)
