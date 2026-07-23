{-# LANGUAGE EmptyDataDeriving #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE QuasiQuotes #-}

module Garnix.FlakeInputAuthorization
  ( checkAuthorization,
    githubAccessTokenNixConfig,
    -- exported for tests
    authorizeGithubPrivateInputs,
    FlakeInput (..),
    GithubFlakeInput (..),
    PrivateInputDecision (..),
    privateInputDecision,
    _parseFlakeMetaData,
    _extractPrivateReposFromErrors,
  )
where

import Control.Lens.Regex.Text qualified as RE
import Cradle
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, Value, withObject, (.:))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Garnix.DB qualified as DB
import Garnix.Entitlements (getConfiguredEvalTimeout)
import Garnix.Monad
import Garnix.Monad.Async (timeoutThrowing)
import Garnix.NixConfig
import Garnix.Prelude
import Garnix.Sandbox
import Garnix.Types hiding (owner, repo)
import Network.URI
import System.Directory.Extra (canonicalizePath, doesPathExist)
import System.FilePath (isAbsolute)

-- | Throws if access should be denied.
-- Otherwise, returns the needed authorization to fetch all flake inputs.
checkAuthorization :: (HasCallStack) => FlakeDir -> RepoConfig -> CommitInfo -> M NixConfig
checkAuthorization flakeDir repoConfig commitInfo = do
  cacheDir <- getNixXdgCacheDir
  nixConfig <- view #userNixConfig
  curDir <- view #workingDir
  flakeDir' <- safeGetAbsoluteFlakeDir flakeDir
  evalTimeout <-
    getConfiguredEvalTimeout
      (commitInfo ^. repoInfo . ghRepoOwner)
      (commitInfo ^. repoInfo . ghRepoName)
  (exitCode, StdoutTrimmed stdout, StderrRaw stderr) <-
    timeoutThrowing evalTimeout (NixCommandTimeout {command = "nix flake metadata"})
      $ (>>= run)
      $ cmd "nix"
      & addArgs ["flake", "metadata", "--json", flakeDir']
      & addNixConfigEnvironment nixConfig
      & setWorkingDir curDir
      & pure
      & inNixSandbox [] (Just cacheDir)
  output <- case exitCode of
    ExitSuccess -> pure stdout
    ExitFailure e -> do
      log Informational $ "'nix flake metadata --json' failed with stderr: " <> cs stderr
      case _extractPrivateReposFromErrors (cs stderr) of
        Nothing ->
          throw
            $ RunProcessError
              { command = "nix",
                arguments = ["flake", "metadata", "--json", cs flakeDir'],
                stdErr = cs stderr,
                stdOut = stdout,
                exitCode = e
              }
        Just privateInputs ->
          throw
            $ OtherError
            $ T.intercalate "\n"
            $ flip map privateInputs
            $ \input ->
              showPretty input <> " is private or doesn't exist (or your flake.lock file is outdated).\nIf it is private and you would like to use it, see https://garnix.io/docs/private_inputs."
  inputs <- aesonDecode "output of 'nix flake metadata --json'" _parseFlakeMetaData output
  githubInputs <- checkInputsAllowed curDir inputs
  let repoInfo' = commitInfo ^. repoInfo
  case repoInfo' ^. forge of
    -- github: input authorization is inherently GitHub API-based (publicity /
    -- collaborator checks of github: refs) and needs the GitHub app. A Gitea
    -- repo has no installation, so we skip it: Gitea repos may depend on public
    -- github: inputs (no token needed); private github: inputs from a Gitea repo
    -- are not supported yet.
    ForgeGitea -> pure $ NixConfig mempty
    ForgeGithub -> authorizeGithubPrivateInputs repoConfig commitInfo repoInfo' githubInputs

-- | GitHub-only: authorize a repo's private github: flake inputs (extracted from
-- 'checkAuthorization' so non-GitHub forges skip it entirely).
authorizeGithubPrivateInputs :: (HasCallStack) => RepoConfig -> CommitInfo -> RepoInfo -> [GithubFlakeInput] -> M NixConfig
-- No github: inputs means there is nothing to authorize, so we neither need nor
-- require the GitHub app installation. Public flakes — and the test suite's
-- minimal local flakes — take this path instead of tripping over a missing
-- installation auth.
authorizeGithubPrivateInputs _ _ _ [] = pure $ NixConfig mempty
authorizeGithubPrivateInputs repoConfig commitInfo repoInfo' githubInputs = do
  iAuth <- case repoInfo' ^. installationAuth of
    Just a -> pure a
    Nothing -> throw $ OtherError "authorizeGithubPrivateInputs: missing GitHub installation auth"
  privateInputs <- filterM (\(GithubFlakeInput owner repo) -> not . isRepoPublic <$> getRepoPublicity iAuth owner repo) githubInputs
  selfRepoPublicity <- getRepoPublicity iAuth (repoInfo' ^. ghRepoOwner) (repoInfo' ^. ghRepoName)
  case privateInputs of
    [] -> pure $ NixConfig mempty
    _
      | isRepoPublic selfRepoPublicity -> do
          selfHost <- view #selfHostMode
          let owner = repoInfo' ^. ghRepoOwner
              repo = repoInfo' ^. ghRepoName
              configuredApproval = repoConfig ^. skipPrivateInputsCheckForCollaborators
          forkApproved <- case commitInfo ^. prFromFork of
            Just fork -> DB.isPrivateInputForkApproved owner repo fork
            Nothing -> pure False
          case privateInputDecision selfHost owner (commitInfo ^. prFromFork) configuredApproval forkApproved of
            PrivateInputsAllowed -> do
              -- In self-host mode private inputs are automatic for trusted
              -- pushes/branches. Persist private-cache routing before any
              -- upload so their closures can never reach the public bucket.
              when selfHost $ DB.ensureRepoPrivateCache owner repo
              pure $ githubAccessTokenNixConfig $ repoInfo' ^. ghToken
            PrivateInputsNeedForkApproval -> do
              case commitInfo ^. prFromFork of
                Just fork -> DB.recordPrivateInputForkBlock owner repo fork
                Nothing -> pure () -- unreachable: NeedForkApproval implies an external fork
              throw
                $ OtherError
                $ "This external fork requested private flake inputs. An administrator must approve external-fork private inputs for "
                <> showPretty owner
                <> "/"
                <> showPretty repo
                <> " before retrying the build. Private dependencies: "
                <> T.unwords (fmap showPretty privateInputs)
            PrivateInputsNeedRepoApproval ->
              throw
                $ OtherError
                $ "Public repository has private dependencies, which is not allowed. Private dependencies: "
                <> T.unwords (fmap showPretty privateInputs)
    _ -> do
      selfHost <- view #selfHostMode
      case commitInfo ^. prFromFork of
        Just _
          | not selfHost ->
              throw
                $ OtherError
                  "Repository has private dependencies, but PR is from fork."
        _ -> do
          forkApproved <- case commitInfo ^. prFromFork of
            Just fork -> DB.isPrivateInputForkApproved (repoInfo' ^. ghRepoOwner) (repoInfo' ^. ghRepoName) fork
            Nothing -> pure False
          case privateInputDecision
            selfHost
            (repoInfo' ^. ghRepoOwner)
            (commitInfo ^. prFromFork)
            (repoConfig ^. skipPrivateInputsCheckForCollaborators)
            forkApproved of
            PrivateInputsNeedForkApproval -> do
              case commitInfo ^. prFromFork of
                Just fork -> DB.recordPrivateInputForkBlock (repoInfo' ^. ghRepoOwner) (repoInfo' ^. ghRepoName) fork
                Nothing -> pure () -- unreachable: NeedForkApproval implies an external fork
              throw
                $ OtherError
                $ "This external fork requested private flake inputs. An administrator must approve external-fork private inputs for "
                <> showPretty (repoInfo' ^. ghRepoOwner)
                <> "/"
                <> showPretty (repoInfo' ^. ghRepoName)
                <> " before retrying the build. Private dependencies: "
                <> T.unwords (fmap showPretty privateInputs)
            _ -> pure ()
      baseRepoCollaborators' <- getRepoCollaborators iAuth (repoInfo' ^. ghRepoOwner) (repoInfo' ^. ghRepoName) <?> "Getting repo collaborators"
      baseRepoCollaborators <- case baseRepoCollaborators' of
        RepoNotFound -> throw $ OtherError "checkAuthorization: base repo not found"
        GhCollaborators collaborators -> pure collaborators
      forM_ privateInputs $ \privateInput -> do
        when ((repoInfo' ^. ghRepoOwner) /= owner privateInput) $ do
          throw $ OtherError $ showPretty privateInput <> " is private or doesn't exist.\nIf it is private and you would like to use it, see https://garnix.io/docs/private_inputs."
        let skipPrivateInputChecks = repoConfig ^. skipPrivateInputsCheckForCollaborators
        unless skipPrivateInputChecks $ do
          thisInputCollaborators' <-
            getRepoCollaborators iAuth (repoInfo' ^. ghRepoOwner) (repo privateInput)
          thisInputCollaborators <- case thisInputCollaborators' of
            RepoNotFound -> throw $ OtherError $ "checkAuthorization: repo " <> (getGhLogin . getGhRepoOwner $ repoInfo' ^. ghRepoOwner) <> "/" <> getGhRepoName (repoInfo' ^. ghRepoName) <> " not found"
            GhCollaborators collaborators -> pure collaborators
          let missingUsers = filter (`notElem` thisInputCollaborators) baseRepoCollaborators
          unless (null missingUsers)
            $ throw
            $ OtherError
            $ "Aborting, as some collaborators of this repository "
            <> "don't have access to a required private dependency ("
            <> showPretty privateInput
            <> "). The users missing permissions are: "
            <> showPretty missingUsers
      pure $ githubAccessTokenNixConfig $ repoInfo' ^. ghToken

-- | Decision at the public-repo/private-input boundary. Self-hosted trusted
-- pushes and same-owner forks are automatic. A fork owned by somebody else
-- needs the one-time repo approval surfaced after its first block. Managed mode
-- retains upstream's explicit per-repo policy.
data PrivateInputDecision
  = PrivateInputsAllowed
  | PrivateInputsNeedForkApproval
  | PrivateInputsNeedRepoApproval
  deriving stock (Eq, Show)

privateInputDecision :: Bool -> GhRepoOwner -> Maybe PrFromFork -> Bool -> Bool -> PrivateInputDecision
privateInputDecision selfHost baseOwner mFork configuredApproval forkApproved
  | configuredApproval = PrivateInputsAllowed
  | not selfHost = PrivateInputsNeedRepoApproval
  | isExternalFork = if forkApproved then PrivateInputsAllowed else PrivateInputsNeedForkApproval
  | otherwise = PrivateInputsAllowed
  where
    isExternalFork = maybe False (not . forkOwnedBy baseOwner) mFork
    forkOwnedBy :: GhRepoOwner -> PrFromFork -> Bool
    forkOwnedBy (GhRepoOwner (GhLogin owner)) (PrFromFork fullName) =
      case T.breakOn "/" fullName of
        (forkOwner, slashAndRepo) ->
          T.toCaseFold forkOwner == T.toCaseFold owner && not (T.null slashAndRepo)

_extractPrivateReposFromErrors :: Text -> Maybe [Text]
_extractPrivateReposFromErrors s =
  case s ^.. [RE.regex|while fetching the input '(github:.*)'\n|] . RE.groups of
    [] -> Nothing
    matches -> Just $ flip map matches $ \case
      [match] -> match
      _ -> error "impossible: regex only has one match group"

githubAccessTokenNixConfig :: GhToken -> NixConfig
githubAccessTokenNixConfig token = NixConfig $ Map.insert "access-tokens" ("github.com=" <> cs (getGhToken token)) mempty

checkInputsAllowed :: FilePath -> [FlakeInput] -> M [GithubFlakeInput]
checkInputsAllowed repoDir inputs = do
  maybes <- forM inputs $ \flakeInput -> case flakeInput of
    Github githubFlakeInput -> pure $ Just githubFlakeInput
    PathInput path -> do
      unlessM (pathInputIsOk repoDir path) $ do
        log Informational $ "disallowed flake input: " <> show (pretty flakeInput)
        throw $ OtherError $ "flake inputs of type 'path:' not allowed: " <> show (pretty flakeInput)
      pure Nothing
    FileInput url -> do
      case uriScheme <$> parseURI url of
        Just "http:" -> pure Nothing
        Just "https:" -> pure Nothing
        _ -> do
          log Informational $ "disallowed flake input: " <> show (pretty flakeInput)
          throw $ OtherError $ "flake input disallowed: " <> show (pretty flakeInput)
    RawRepoUrlInput url -> do
      case uriScheme <$> parseURI url of
        Just "http:" -> pure Nothing
        Just "https:" -> pure Nothing
        Just "ssh:" -> pure Nothing
        _ -> do
          log Informational $ "disallowed flake input: " <> show (pretty flakeInput)
          throw $ OtherError $ "flake input disallowed: " <> show (pretty flakeInput)
  pure $ catMaybes maybes
  where
    pathInputIsOk :: FilePath -> FilePath -> M Bool
    pathInputIsOk repoDir inputPath
      | isAbsolute inputPath = pure False
      | otherwise = do
          let combined = repoDir </> inputPath
          exists <- liftIO $ doesPathExist combined
          if not exists
            then pure False
            else do
              normalizedInputPath <- liftIO $ canonicalizePath combined
              pure $ (repoDir <> "/") `isPrefixOf` normalizedInputPath

data FlakeInput
  = Github GithubFlakeInput
  | PathInput FilePath
  | FileInput FilePath
  | RawRepoUrlInput String
  deriving stock (Show, Eq, Ord)

instance Pretty FlakeInput where
  pretty = \case
    Github input -> pretty input
    PathInput path -> "path:" <> pretty path
    FileInput url -> pretty url
    RawRepoUrlInput url -> pretty url

data GithubFlakeInput = GithubFlakeInput {owner :: GhRepoOwner, repo :: GhRepoName}
  deriving stock (Show, Eq, Ord)

instance Pretty GithubFlakeInput where
  pretty GithubFlakeInput {owner, repo} =
    "github:" <> pretty owner <> "/" <> pretty repo

_parseFlakeMetaData :: Value -> Parser [FlakeInput]
_parseFlakeMetaData json = do
  locks <- withObject "flake metadata" pure json >>= (.: "locks")
  nodes <- locks .: "nodes"
  rootKey <- locks .: "root"
  nodes :: KeyMap Value <-
    KeyMap.delete rootKey
      <$> parseJSON nodes
  fmap catMaybes
    $ forM (KeyMap.elems nodes)
    $ withObject "flake input node"
    $ \o -> do
      parseFlakeInput o "original"

parseFlakeInput :: KeyMap Value -> Text -> Parser (Maybe FlakeInput)
parseFlakeInput input key = do
  obj <- input .: fromString (cs key)
  typ :: Maybe Text <- obj .: "type"
  case typ of
    Just "indirect" -> do
      when
        (key == "locked")
        (fail "Type of locked inputs can't be \"indirect\".")
      parseFlakeInput input "locked"
    Just "github" ->
      Just . Github <$> (GithubFlakeInput <$> obj .: "owner" <*> obj .: "repo")
    Just "path" -> do
      Just . PathInput <$> obj .: "path"
    Just "file" -> do
      Just . FileInput <$> obj .: "url"
    Just "git" -> do
      Just . RawRepoUrlInput <$> obj .: "url"
    Just "hg" -> do
      Just . RawRepoUrlInput <$> obj .: "url"
    Just typ | typ `elem` otherBlessedTypes -> pure Nothing
    Just typ ->
      fail $ "unsupported flake input type: " <> cs typ
    Nothing ->
      fail "missing flake input type"

otherBlessedTypes :: [Text]
otherBlessedTypes = ["tarball", "gitlab", "sourcehut"]
