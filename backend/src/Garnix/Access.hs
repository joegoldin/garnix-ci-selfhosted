module Garnix.Access
  ( Access (..),
    getBuildWithAccess,
    getRunWithAccess,
    hasAccessTo,
    hasAccessToRepo,
    getRepoPublicityForForge,
  )
where

import Garnix.DB qualified as DB
import Garnix.GiteaInterface (giteaGetRepoCollaborators, giteaGetRepoPublicity)
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types as Types
import GitHub.Data.Id (Id (Id))

data Access = Read | Cancel

getRunWithAccess :: Access -> Maybe User -> RunId -> M Run
getRunWithAccess access user' runId = do
  let accessCheck = case access of
        Read -> hasAccessTo
        Cancel -> canCancelBuild
  run' <- DB.getRun runId
  run <- case run' of
    Just run -> pure run
    Nothing -> throw (NoSuchRun runId)
  installationId <- getGarnixInstallationId (run ^. repoUser) (run ^. repoName)
  iAuth <- case installationId of
    Nothing -> throw $ OtherError "Failed to look up installation auth"
    Just id -> getInstallation (Id $ fromInteger id)
  repoPublicity <- getRepoPublicity iAuth (run ^. repoUser) (run ^. repoName)
  hasAccess <- accessCheck user' repoPublicity (run ^. reqUser) (run ^. repoUser) (run ^. repoName)
  when (not hasAccess) $ throw (NoSuchRun runId)
  pure run

getBuildWithAccess :: Access -> Maybe User -> BuildId -> M Build
getBuildWithAccess access user' buildId = do
  let accessCheck = case access of
        Read -> hasAccessTo
        Cancel -> canCancelBuild
  build <- DB.getBuild buildId
  hasAccess <- accessCheck user' (build ^. repoIsPublic) (build ^. reqUser) (build ^. repoUser) (build ^. repoName)
  when (not hasAccess) $ throw (NoSuchBuild buildId)
  pure build

hasAccessTo :: Maybe User -> RepoPublicity -> GhLogin -> GhRepoOwner -> GhRepoName -> M Bool
hasAccessTo user' repoIsPublic reqUser owner name
  | user' ^? _Just . githubLogin == Just reqUser = pure True
  | otherwise = hasAccessToRepo user' repoIsPublic owner name

hasAccessToRepo :: Maybe User -> RepoPublicity -> GhRepoOwner -> GhRepoName -> M Bool
hasAccessToRepo user' repoIsPublic owner name
  | isRepoPublic repoIsPublic = pure True
  | user' ^? _Just . subscriptionType == Just Admin = pure True
  | otherwise = case user' of
      Nothing -> pure False
      Just user -> do
        collaborators <- getCollaborators owner name
        case collaborators of
          RepoNotFound -> pure False
          GhCollaborators collaborators' -> pure $ (user ^. githubLogin) `elem` collaborators'

-- | Collaborators of a repo, dispatched by forge: GitHub via its installation,
-- or Gitea via its API when the repo has no GitHub installation. Lets private
-- Gitea repos be gated on Gitea collaborators (by login), like GitHub.
getCollaborators :: GhRepoOwner -> GhRepoName -> M GhCollaborators
getCollaborators owner repo = do
  installationId <- getGarnixInstallationId owner repo
  case installationId of
    Just id -> do
      iAuth <- getInstallation (Id $ fromInteger id)
      getRepoCollaborators iAuth owner repo
    Nothing ->
      view #giteaConfig >>= \case
        Nothing -> pure RepoNotFound
        Just cfg ->
          try (giteaGetRepoCollaborators cfg owner repo) >>= \case
            Left _ -> pure RepoNotFound
            Right collaborators -> pure collaborators

-- | Publicity of a repo, dispatched by forge (GitHub installation, else Gitea).
-- Throws 'NoSuchRepo' if the repo isn't found on any configured forge — used by
-- the web UI's repo view so Gitea repos render instead of 404ing.
getRepoPublicityForForge :: (HasCallStack) => GhRepoOwner -> GhRepoName -> M RepoPublicity
getRepoPublicityForForge owner repo =
  getGarnixInstallationId owner repo >>= \case
    Just id -> do
      iAuth <- getInstallation (Id $ fromInteger id)
      getRepoPublicity iAuth owner repo
    Nothing ->
      view #giteaConfig >>= \case
        Nothing -> throw NoSuchRepo {_owner = owner, _name = repo}
        Just cfg ->
          try (giteaGetRepoPublicity cfg owner repo) >>= \case
            Left _ -> throw NoSuchRepo {_owner = owner, _name = repo}
            Right p -> pure p

canCancelBuild :: Maybe User -> RepoPublicity -> GhLogin -> GhRepoOwner -> GhRepoName -> M Bool
canCancelBuild user' _ reqUser owner name
  | user' ^? _Just . subscriptionType == Just Admin = pure True
  | user' ^? _Just . githubLogin == Just reqUser = pure True
  | otherwise = case user' of
      Nothing -> pure False
      Just user -> do
        collaborators <- getCollaborators owner name
        case collaborators of
          RepoNotFound -> pure False
          GhCollaborators collaborators' -> pure $ (user ^. githubLogin) `elem` collaborators'
