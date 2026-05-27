{-# LANGUAGE TemplateHaskell #-}

module Garnix.Types.ExternalLenses where

import Control.Lens
import Garnix.Types.MakeLensHelpers
import GitHub.Data.Webhooks.Events
import GitHub.Data.Webhooks.Payload

makeLensesWith (externalTypes "evCheckSuite") ''CheckSuiteEvent
makeLensesWith (externalTypes "evPullReq") ''PullRequestEvent
makeLensesWith (externalTypes "whChecksInstallation") ''HookChecksInstallation
makeLensesWith (externalTypes "whCheckSuite") ''HookCheckSuite
makeLensesWith (externalTypes "whCheckSuiteApp") ''HookCheckSuiteApp
makeLensesWith (externalTypes "whPullReq") ''HookPullRequest
makeLensesWith (externalTypes "whPullReqTarget") ''PullRequestTarget
makeLensesWith (externalTypes "whRepo") ''HookRepository
makeLensesWith (externalTypes "whUser") ''HookUser
