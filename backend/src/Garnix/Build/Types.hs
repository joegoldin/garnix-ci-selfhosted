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
    outputs :: Nix.BuildOutputs
  }
  deriving stock (Show, Generic, Eq)
