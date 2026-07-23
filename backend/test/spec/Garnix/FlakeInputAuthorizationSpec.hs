module Garnix.FlakeInputAuthorizationSpec where

import Data.Aeson (Value)
import Data.Aeson.Types (parseEither)
import Data.Yaml.TH (yamlQQ)
import Garnix.DB qualified as DB
import Garnix.FlakeInputAuthorization
import Garnix.Prelude
import Garnix.TestHelpers (defaultCommitInfo, truncateDBM)
import Garnix.TestHelpers.GithubInterface qualified as GH
import Garnix.TestHelpers.Monad
import Garnix.Types
import Test.Hspec

spec :: Spec
spec = do
  describe "privateInputDecision" $ do
    let owner = GhRepoOwner (GhLogin "joegoldin")
    it "automatically allows private inputs for trusted self-host pushes"
      $ privateInputDecision True owner Nothing False False
      `shouldBe` PrivateInputsAllowed

    it "automatically allows a same-owner fork"
      $ privateInputDecision True owner (Just (PrFromFork "joegoldin/repo-fork")) False False
      `shouldBe` PrivateInputsAllowed

    it "compares github fork owners case-insensitively"
      $ privateInputDecision True owner (Just (PrFromFork "JoeGoldin/repo-fork")) False False
      `shouldBe` PrivateInputsAllowed

    it "requires approval after an external fork requests private inputs"
      $ privateInputDecision True owner (Just (PrFromFork "someone-else/repo-fork")) False False
      `shouldBe` PrivateInputsNeedForkApproval

    it "allows an approved external fork and keeps managed-mode policy separate" $ do
      privateInputDecision True owner (Just (PrFromFork "someone-else/repo-fork")) False True
        `shouldBe` PrivateInputsAllowed
      privateInputDecision False owner Nothing False False
        `shouldBe` PrivateInputsNeedRepoApproval
      privateInputDecision False owner Nothing True False
        `shouldBe` PrivateInputsAllowed

  describe "self-host private-input authorization" $ inM $ beforeM_ truncateDBM $ do
    let privateInput = GithubFlakeInput "owner" "private-input"
        publicCommit = defaultCommitInfo & repoPublicity .~ RepoIsPublic True

    it "auto-private-caches a trusted public repo without creating an approval request"
      $ GH.withFakeGithubInterface
      $ \github -> do
        GH.mkRepo github "owner" "repo" (#publicity .~ RepoIsPublic True)
        GH.mkRepo github "owner" "private-input" (#publicity .~ RepoIsPublic False)

        _ <-
          local (#selfHostMode .~ True)
            $ authorizeGithubPrivateInputs defaultRepoConfig publicCommit (publicCommit ^. repoInfo) [privateInput]
        config <- DB.getRepoConfig "owner" "repo"
        config ^. privateCache `shouldBeM` True
        config ^. skipPrivateInputsCheckForCollaborators `shouldBeM` False
        DB.getPrivateInputForkApprovalRequests `shouldReturnM` []

    it "records an external-fork block, then permits an approved retry"
      $ GH.withFakeGithubInterface
      $ \github -> do
        GH.mkRepo github "owner" "repo" (#publicity .~ RepoIsPublic True)
        GH.mkRepo github "owner" "private-input" (#publicity .~ RepoIsPublic False)
        let forkCommit = publicCommit & prFromFork ?~ PrFromFork "outsider/repo-fork"

        void
          $ try
          $ local (#selfHostMode .~ True)
          $ authorizeGithubPrivateInputs defaultRepoConfig forkCommit (forkCommit ^. repoInfo) [privateInput]
        requests <- DB.getPrivateInputForkApprovalRequests
        fmap (\(owner, repo, forkFullName, allowed, _blockedAt) -> (owner, repo, forkFullName, allowed)) requests
          `shouldBeM` [("owner", "repo", "outsider/repo-fork", False)]

        DB.setPrivateInputForkApproval "owner" "repo" (PrFromFork "outsider/repo-fork") True
        approvedConfig <- DB.getRepoConfig "owner" "repo"
        _ <-
          local (#selfHostMode .~ True)
            $ authorizeGithubPrivateInputs approvedConfig forkCommit (forkCommit ^. repoInfo) [privateInput]
        finalConfig <- DB.getRepoConfig "owner" "repo"
        finalConfig ^. privateCache `shouldBeM` True
        -- Per-fork approval must not set the repo-wide collaborator-skip flag.
        finalConfig ^. skipPrivateInputsCheckForCollaborators `shouldBeM` False

  describe "_extractPrivateReposFromErrors" $ do
    it "extracts a repo name from from nix error messages for private repos" $ do
      _extractPrivateReposFromErrors "while fetching the input 'github:foo'\n"
        `shouldBe` Just ["github:foo"]

    it "ignores other messages" $ do
      _extractPrivateReposFromErrors "foo\nwhile fetching the input 'github:foo'\nbar\n"
        `shouldBe` Just ["github:foo"]

    it "extracts multiple repo names" $ do
      _extractPrivateReposFromErrors "while fetching the input 'github:foo'\nwhile fetching the input 'github:bar'\n"
        `shouldBe` Just ["github:foo", "github:bar"]

    it "returns `Nothing` when there's no match" $ do
      _extractPrivateReposFromErrors "foo\nbar\n"
        `shouldBe` Nothing

  describe "_parseFlakeInfo" $ do
    let test :: Value -> IO [FlakeInput]
        test json = do
          let result = parseEither _parseFlakeMetaData json
          case result of
            Right inputs -> pure inputs
            Left err -> error $ cs err

    it "parses github inputs" $ do
      inputs <-
        test
          [yamlQQ|
          locks:
            root: root
            nodes:
              root:
                inputs:
                  foo: foo
              foo:
                original:
                  owner: test-owner
                  repo: test-repo
                  type: github
        |]
      inputs `shouldBe` [Github $ GithubFlakeInput "test-owner" "test-repo"]

    it "parses indirect inputs" $ do
      inputs <-
        test
          [yamlQQ|
          locks:
            root: root
            nodes:
              root:
                inputs:
                  foo: foo
              foo:
                locked:
                  owner: test-owner
                  repo: test-repo
                  type: github
                original:
                  id: test-repo
                  type: indirect
        |]
      inputs `shouldBe` [Github $ GithubFlakeInput "test-owner" "test-repo"]

    it "discards other blessed types of flake inputs" $ do
      inputs <-
        test
          [yamlQQ|
          locks:
            root: root
            nodes:
              root:
                inputs:
                  foo: foo
              foo:
                original:
                  url: test-url
                  type: tarball
        |]
      inputs `shouldBe` []

    it "discards indirect inputs of other blessed types" $ do
      inputs <-
        test
          [yamlQQ|
            locks:
              root: root
              nodes:
                root:
                  inputs:
                    pathInput: pathInput
                pathInput:
                  locked:
                    path: test-url
                    type: tarball
                  original:
                    id: pathInput
                    type: indirect
          |]
      inputs `shouldBe` []

    it "extracts transitive flake inputs" $ do
      inputs <-
        test
          [yamlQQ|
            locks:
              root: root
              nodes:
                root:
                  inputs:
                    other-flake: other-flake
                other-flake:
                  inputs:
                    transitive-input: transitive-input
                  original:
                    owner: test-owner
                    repo: test-repo
                    type: github
                transitive-input:
                  locked:
                    path: /test-file-input
                    type: path
                  flake: false
                  original:
                    path: /test-file-input
                    type: path
          |]
      sort inputs `shouldBe` sort [Github $ GithubFlakeInput "test-owner" "test-repo", PathInput "/test-file-input"]
