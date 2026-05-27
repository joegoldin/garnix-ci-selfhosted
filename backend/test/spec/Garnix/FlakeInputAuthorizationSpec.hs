module Garnix.FlakeInputAuthorizationSpec where

import Data.Aeson (Value)
import Data.Aeson.Types (parseEither)
import Data.Yaml.TH (yamlQQ)
import Garnix.FlakeInputAuthorization
import Garnix.Prelude
import Test.Hspec

spec :: Spec
spec = do
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
