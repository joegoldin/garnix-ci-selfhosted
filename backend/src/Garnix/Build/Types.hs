{-# LANGUAGE TemplateHaskell #-}

module Garnix.Build.Types where

import Garnix.Nix.Types qualified as Nix
import Garnix.Prelude
import Garnix.Types

data AppBuildDetails = AppBuildDetails
  { _appBuildDetailsAppExecPath :: Nix.AppExecPath,
    _appBuildDetailsDrvPath :: Nix.DrvPath
  }

makeFields ''AppBuildDetails

data EvaluationResult = EvaluationResult
  { derivation :: Nix.DrvPath,
    toUpload :: [Nix.StorePath],
    outputs :: Nix.BuildOutputs,
    -- | Outputs whose store path nix cannot know before building: those of a
    -- derivation depending on a dynamic derivation's output
    -- (builtins.outputOf) or on a floating content-addressed one. They are
    -- resolved once the build has realised them.
    unresolvedOutputs :: [Text]
  }
  deriving stock (Show, Generic, Eq)
