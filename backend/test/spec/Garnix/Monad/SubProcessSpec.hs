module Garnix.Monad.SubProcessSpec where

import Control.Concurrent.MVar
import Cradle
import Data.IORef
import Data.String.Interpolate (i)
import Data.String.Interpolate.Util (unindent)
import Data.Text qualified as T
import Garnix.Async (timeout)
import Garnix.Duration
import Garnix.Monad.SubProcess
import Garnix.Prelude
import Garnix.TestHelpers (waitFor)
import Garnix.TestHelpers.Monad
import Garnix.TestInstances ()
import Garnix.Types
import Servant.Server (ServerError (..))
import System.IO
import Test.Hspec
import Test.Mockery.Directory (inTempDirectory)

spec :: Spec
spec = do
  describe "withUtf8LinesStream" $ around_ inTempDirectory $ do
    it "allows streaming log lines from stdout" $ do
      writeFile "script" "echo foo\necho bar"
      ref <- newIORef []
      withUtf8LinesStream (\line -> modifyIORef' ref (++ [line])) $ \handle ->
        run_
          $ cmd "bash"
          & addArgs ["script" :: String]
          & addStdoutHandle handle
      readIORef ref `shouldReturn` ["foo", "bar"]

    it "allows streaming log lines from stdout and stderr" $ do
      writeFile "script"
        $ unindent
          [i|
            echo foo
            echo bar 1>&2
          |]
      ref <- newIORef []
      let consumer line = do
            atomicModifyIORef' ref (\acc -> (acc ++ [line], ()))
      withUtf8LinesStream consumer $ \handle ->
        run_
          $ cmd "bash"
          & addArgs ["script" :: String]
          & addStdoutHandle handle
          & addStderrHandle handle
      waitFor (fromSeconds @Int 5) $ do
        sort <$> readIORef ref `shouldReturn` ["bar", "foo"]

    it "does not leak file handles" $ do
      handleMVar <- newEmptyMVar
      let consumer _ = pure ()
      void $ timeout (fromSeconds @Int 1) $ withUtf8LinesStream consumer $ \handle -> do
        putMVar handleMVar handle
        run_
          $ cmd "sleep"
          & addArgs ["100000" :: String]
          & addStdoutHandle handle
      isClosed <- hIsClosed =<< readMVar handleMVar
      isClosed `shouldBe` True

  inM $ aroundM_ suppressLogsWhenPassing $ describe "error handling" $ do
    let getAllRenderings error =
          ( showPretty (err error),
            errReasonPhrase (servantizeError error),
            errBody (servantizeError error)
          )

    it "prints errors for failing commands for users" $ do
      Left error <- try $ runSubProcess_ (cmd "git" & addArgs ["invalid-command" :: Text])
      getAllRenderings error
        `shouldBeM` ( T.unlines
                        [ "Command 'git invalid-command' failed with exit code 1. Standard err was:",
                          "git: 'invalid-command' is not a git command. See 'git --help'."
                        ],
                      "Bad Request",
                      cs
                        $ T.unlines
                          [ "git invalid-command failed with exit code 1",
                            "Stderr:",
                            "git: 'invalid-command' is not a git command. See 'git --help'."
                          ]
                    )

    it "redacts github access tokens from urls" $ do
      Left error <-
        try
          $ runSubProcess_
            ( cmd "git"
                & addArgs
                  [ "invalid-command",
                    "https://x-access-token:ghs_ghsomegithubtoken0000000000000000000@github.com/soenkehahn/garnix-test-repo.git" :: Text
                  ]
            )
      getAllRenderings error
        `shouldBeM` ( T.unlines
                        [ "Command 'git invalid-command https://x-access-token:XXXXXXXXXXXXXXXX@github.com/soenkehahn/garnix-test-repo.git' failed with exit code 1.",
                          "Standard err was:",
                          "git: 'invalid-command' is not a git command. See 'git --help'."
                        ],
                      "Bad Request",
                      cs
                        $ T.unlines
                          [ "git invalid-command https://x-access-token:XXXXXXXXXXXXXXXX@github.com/soenkehahn/garnix-test-repo.git failed with exit code 1",
                            "Stderr:",
                            "git: 'invalid-command' is not a git command. See 'git --help'."
                          ]
                    )
