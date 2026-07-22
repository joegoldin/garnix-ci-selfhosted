module Garnix.BuildLogs
  ( buildInternalLogProcessor,
    mkInternalLogProcessorState,
    mkTrackedInternalLogProcessorState,
    newBuildWaitTracker,
    setBuildWaitStage,
    clearBuildWait,
    readBuildWaitNodes,
    buildWaitNodes,
    processLogsForGithub,
    processMessage,
    shouldKeepLn,
  )
where

import Control.Concurrent
import Data.Aeson hiding (Error)
import Data.ByteString.Lazy qualified as BS
import Data.Char (isAlphaNum, toLower)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.String.AnsiEscapeCodes.Strip.Text (stripAnsiEscapeCodes)
import Data.Text qualified as T
import Garnix.BuildLogs.Internal qualified as LogsInternal
import Garnix.BuildLogs.Types
  ( BuildWaitActivity (..),
    BuildWaitState (..),
    BuildWaitTracker (..),
    LogLine (LogLine),
    mkLogLine,
  )
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import System.FilePath (takeFileName)

-- * Common

processMessage :: Text -> Text
processMessage =
  T.unlines
    . filter shouldKeepLn
    . T.lines
    . obfuscateGithubToken
    . stripAnsiEscapeCodes

shouldKeepLn :: Text -> Bool
shouldKeepLn ln =
  not ("error (ignored): error: SQLite database" `T.isPrefixOf` ln)
    && not ("garnixMacBuilder" `T.isInfixOf` ln)
    && not ("macMini" `T.isInfixOf` ln)
    && not ("/run/secrets/garnix_server_ssh" `T.isInfixOf` ln)

-- * Parsing internal nix logs for opensearch

data InternalLogProcessorState
  = InternalLogProcessorState
      (MVar (Map LogsInternal.InternalId Text))
      (MVar (Map LogsInternal.InternalId PackageName))
      (Maybe (BuildWaitTracker, BuildId))

mkInternalLogProcessorState :: M InternalLogProcessorState
mkInternalLogProcessorState = liftIO $ InternalLogProcessorState <$> newMVar mempty <*> newMVar mempty <*> pure Nothing

mkTrackedInternalLogProcessorState :: BuildWaitTracker -> BuildId -> M InternalLogProcessorState
mkTrackedInternalLogProcessorState tracker buildId = do
  InternalLogProcessorState phases packages _ <- mkInternalLogProcessorState
  pure $ InternalLogProcessorState phases packages (Just (tracker, buildId))

newBuildWaitTracker :: (MonadIO m) => m BuildWaitTracker
newBuildWaitTracker = liftIO $ BuildWaitTracker <$> newMVar mempty

setBuildWaitStage :: (MonadIO m) => BuildWaitTracker -> BuildId -> Text -> m ()
setBuildWaitStage (BuildWaitTracker states) buildId stage = liftIO $ do
  now <- getCurrentTime
  modifyMVar_ states $ \allStates ->
    pure
      $ Map.alter
        ( \case
            Nothing -> Just $ BuildWaitState stage now now mempty
            Just state
              | buildWaitStage state == stage -> Just state {buildWaitLastActivityAt = now}
              | otherwise -> Just $ BuildWaitState stage now now mempty
        )
        (waitBuildKey buildId)
        allStates

clearBuildWait :: (MonadIO m) => BuildWaitTracker -> BuildId -> m ()
clearBuildWait (BuildWaitTracker states) buildId =
  liftIO $ modifyMVar_ states $ pure . Map.delete (waitBuildKey buildId)

readBuildWaitNodes :: (MonadIO m) => BuildWaitTracker -> BuildId -> m [WaitNode]
readBuildWaitNodes (BuildWaitTracker states) buildId = do
  mState <- liftIO $ Map.lookup (waitBuildKey buildId) <$> readMVar states
  pure $ maybe [] (pure . waitStateNode buildId) mState

-- | Return live detail when it is available, otherwise a durable, honest
-- fallback derived from the build row. This makes deploy/restart recovery
-- visible even before the new backend has received another Nix event.
buildWaitNodes :: (MonadIO m) => BuildWaitTracker -> Build -> Maybe UTCTime -> m [WaitNode]
buildWaitNodes tracker build runStartedAt
  | isJust (build ^. status) = pure []
  | otherwise = do
      live <- readBuildWaitNodes tracker (build ^. id)
      pure $ if null live then [fallbackWaitNode build runStartedAt] else live

fallbackWaitNode :: Build -> Maybe UTCTime -> WaitNode
fallbackWaitNode build runStartedAt =
  WaitNode
    { _waitNodeId = "stage:" <> buildIdText <> ":fallback",
      _waitNodeKind = "stage",
      _waitNodeLabel = stageLabel,
      _waitNodeDetail = Nothing,
      _waitNodeHref = Nothing,
      _waitNodeStartedAt = runStartedAt <|> Just (build ^. startTime),
      _waitNodeLastActivityAt = runStartedAt,
      _waitNodeChildren = drvNode
    }
  where
    buildIdText = getHashId . getBuildId $ build ^. id
    stageLabel
      | isNothing runStartedAt = "Waiting for build slot"
      | isJust (build ^. drvPath) = "Waiting for Nix activity"
      | otherwise = "Evaluating package"
    drvNode = case build ^. drvPath of
      Nothing -> []
      Just drvPath ->
        [ WaitNode
            { _waitNodeId = "derivation:" <> buildIdText <> ":fallback",
              _waitNodeKind = "derivation",
              _waitNodeLabel = cs $ takeFileName drvPath,
              _waitNodeDetail = Nothing,
              _waitNodeHref = Just $ "/build/" <> buildIdText,
              _waitNodeStartedAt = runStartedAt,
              _waitNodeLastActivityAt = runStartedAt,
              _waitNodeChildren = []
            }
        ]

waitStateNode :: BuildId -> BuildWaitState -> WaitNode
waitStateNode buildId state =
  WaitNode
    { _waitNodeId = "stage:" <> buildIdText,
      _waitNodeKind = "stage",
      _waitNodeLabel = buildWaitStage state,
      _waitNodeDetail = Nothing,
      _waitNodeHref = Nothing,
      _waitNodeStartedAt = Just $ buildWaitStageStartedAt state,
      _waitNodeLastActivityAt = Just $ buildWaitLastActivityAt state,
      _waitNodeChildren = map (activityNode buildId state) rootActivities
    }
  where
    buildIdText = getHashId $ getBuildId buildId
    activities = buildWaitActivities state
    rootActivities =
      [ activityId
        | (activityId, activity) <- Map.toAscList activities,
          maybe True (`Map.notMember` activities) (buildWaitActivityParent activity)
      ]

activityNode :: BuildId -> BuildWaitState -> Int64 -> WaitNode
activityNode buildId state activityId =
  WaitNode
    { _waitNodeId = "nix:" <> show activityId,
      _waitNodeKind = buildWaitActivityKind activity,
      _waitNodeLabel = buildWaitActivityLabel activity,
      _waitNodeDetail = buildWaitActivityDetail activity,
      _waitNodeHref = buildWaitActivityHref activity <|> buildHref,
      _waitNodeStartedAt = Just $ buildWaitActivityStartedAt activity,
      _waitNodeLastActivityAt = Just $ buildWaitActivityLastActivityAt activity,
      _waitNodeChildren = builderNode <> phaseNode <> nestedNodes
    }
  where
    activity = buildWaitActivities state Map.! activityId
    buildHref
      | buildWaitActivityKind activity == "derivation" = Just $ "/build/" <> getHashId (getBuildId buildId)
      | otherwise = Nothing
    builderNode = case buildWaitActivityBuilder activity of
      Just builder
        | not (T.null $ T.strip builder) ->
            [ WaitNode
                { _waitNodeId = "builder:" <> show activityId,
                  _waitNodeKind = "builder",
                  _waitNodeLabel = builder,
                  _waitNodeDetail = Nothing,
                  _waitNodeHref = Just $ "/monitoring#builder-" <> slugify builder,
                  _waitNodeStartedAt = Just $ buildWaitActivityStartedAt activity,
                  _waitNodeLastActivityAt = Just $ buildWaitActivityLastActivityAt activity,
                  _waitNodeChildren = []
                }
            ]
      _ -> []
    phaseNode = case buildWaitActivityPhase activity of
      Just phase ->
        [ WaitNode
            { _waitNodeId = "phase:" <> show activityId,
              _waitNodeKind = "phase",
              _waitNodeLabel = phase,
              _waitNodeDetail = Nothing,
              _waitNodeHref = Nothing,
              _waitNodeStartedAt = Just $ buildWaitActivityStartedAt activity,
              _waitNodeLastActivityAt = Just $ buildWaitActivityLastActivityAt activity,
              _waitNodeChildren = []
            }
        ]
      Nothing -> []
    nestedNodes =
      [ activityNode buildId state childId
        | (childId, child) <- Map.toAscList $ buildWaitActivities state,
          buildWaitActivityParent child == Just activityId
      ]

slugify :: Text -> Text
slugify = T.map $ \c -> if isAlphaNum c then toLower c else '-'

buildInternalLogProcessor :: (LogLine -> M ()) -> InternalLogProcessorState -> (String -> M ())
buildInternalLogProcessor consumer (InternalLogProcessorState phaseById pkgsById waitTracking) internalLogLine = do
  let jsonStr = BS.stripPrefix "@nix" (cs internalLogLine)
      parsedLine = case jsonStr of
        Just line -> eitherDecode' line
        Nothing -> Left $ "Expected internal log line from nix but got: " <> internalLogLine
  case parsedLine of
    Right start@(LogsInternal.Start id _ _ (LogsInternal.Build drvPath _ _)) -> do
      setPackage id $ drvPathToPkgName drvPath
      trackStart start
    Right start@(LogsInternal.Start {}) -> trackStart start
    Right (LogsInternal.Stop id) -> trackStop id
    Right (LogsInternal.Result id (LogsInternal.SetPhase phase)) -> setPhase id phase >> trackPhase id phase
    Right (LogsInternal.Result id (LogsInternal.Progress progress)) -> trackProgress id progress
    Right (LogsInternal.Result id (LogsInternal.LogLine log)) -> LogLine <$> getPkgForId id <*> getPhaseForId id <*> pure log >>= consumer
    Right (LogsInternal.Msg log) -> consumer $ mkLogLine log
    Right _ -> pure ()
    Left err -> log Warning $ cs err
  where
    setPackage :: LogsInternal.InternalId -> PackageName -> M ()
    setPackage id pkgName = liftIO $ modifyMVar_ pkgsById $ pure . Map.insert id pkgName

    getPkgForId :: LogsInternal.InternalId -> M (Maybe PackageName)
    getPkgForId id = liftIO $ Map.lookup id <$> readMVar pkgsById

    setPhase :: LogsInternal.InternalId -> Text -> M ()
    setPhase id phase = liftIO $ modifyMVar_ phaseById $ pure . Map.insert id phase

    getPhaseForId :: LogsInternal.InternalId -> M (Maybe Text)
    getPhaseForId id = liftIO $ Map.lookup id <$> readMVar phaseById

    trackStart :: LogsInternal.InternalBuildLogLine -> M ()
    trackStart (LogsInternal.Start id parent _ start) = forM_ waitTracking $ \(tracker, buildId) -> do
      now <- liftIO getCurrentTime
      let parentId = case LogsInternal.getInternalId <$> parent of
            Just 0 -> Nothing
            other -> other
      forM_ (activityFromStart now parentId start) $ \activity ->
        modifyWaitState tracker buildId now $ \state ->
          state
            { buildWaitActivities =
                trimActivities
                  $ Map.insert (LogsInternal.getInternalId id) activity (buildWaitActivities state)
            }
    trackStart _ = pure ()

    trackStop id = forM_ waitTracking $ \(tracker, buildId) -> do
      now <- liftIO getCurrentTime
      modifyWaitState tracker buildId now $ \state ->
        state {buildWaitActivities = Map.delete (LogsInternal.getInternalId id) $ buildWaitActivities state}

    trackPhase id phase = forM_ waitTracking $ \(tracker, buildId) -> do
      now <- liftIO getCurrentTime
      modifyWaitState tracker buildId now $ \state ->
        state
          { buildWaitActivities =
              Map.adjust
                (\activity -> activity {buildWaitActivityPhase = Just phase, buildWaitActivityLastActivityAt = now})
                (LogsInternal.getInternalId id)
                (buildWaitActivities state)
          }

    trackProgress id progress = forM_ waitTracking $ \(tracker, buildId) -> do
      now <- liftIO getCurrentTime
      let detail = show (LogsInternal.done progress) <> " / " <> show (LogsInternal.expected progress)
      modifyWaitState tracker buildId now $ \state ->
        state
          { buildWaitActivities =
              Map.adjust
                (\activity -> activity {buildWaitActivityDetail = Just detail, buildWaitActivityLastActivityAt = now})
                (LogsInternal.getInternalId id)
                (buildWaitActivities state)
          }

modifyWaitState :: BuildWaitTracker -> BuildId -> UTCTime -> (BuildWaitState -> BuildWaitState) -> M ()
modifyWaitState (BuildWaitTracker states) buildId now update = liftIO
  $ modifyMVar_ states
  $ \allStates ->
    pure
      $ Map.adjust
        (\state -> (update state) {buildWaitLastActivityAt = now})
        (waitBuildKey buildId)
        allStates

waitBuildKey :: BuildId -> Text
waitBuildKey = getHashId . getBuildId

activityFromStart :: UTCTime -> Maybe Int64 -> LogsInternal.InternalBuildLogLineStart -> Maybe BuildWaitActivity
activityFromStart now parent start = case start of
  LogsInternal.Build drvPath builder _ -> Just $ activity "derivation" (getPackageName $ drvPathToPkgName drvPath) Nothing (nonEmpty builder)
  LogsInternal.Builds label -> Just $ activity "builds" label Nothing Nothing
  LogsInternal.CopyPaths label -> Just $ activity "copy" label Nothing Nothing
  LogsInternal.Unknown label -> Just $ activity "activity" label Nothing Nothing
  LogsInternal.QueryPathInfo label -> Just $ activity "query" label Nothing Nothing
  LogsInternal.FileTransfer label -> Just $ activity "transfer" label Nothing Nothing
  LogsInternal.Realize label -> Just $ activity "realize" label Nothing Nothing
  LogsInternal.OtherStartType -> Nothing
  where
    activity kind label href builder =
      BuildWaitActivity
        { buildWaitActivityParent = parent,
          buildWaitActivityKind = kind,
          buildWaitActivityLabel = label,
          buildWaitActivityDetail = Nothing,
          buildWaitActivityHref = href,
          buildWaitActivityStartedAt = now,
          buildWaitActivityLastActivityAt = now,
          buildWaitActivityBuilder = builder,
          buildWaitActivityPhase = Nothing
        }
    nonEmpty value
      | T.null $ T.strip value = Nothing
      | otherwise = Just value

-- Active Nix activities should ordinarily be small. A hard bound prevents a
-- malformed/missing stop stream from growing process memory without limit.
trimActivities :: Map Int64 BuildWaitActivity -> Map Int64 BuildWaitActivity
trimActivities activities
  | Map.size activities <= 2048 = activities
  | otherwise = trimActivities $ Map.deleteMin activities

drvPathToPkgName :: Text -> PackageName
drvPathToPkgName = PackageName . T.dropEnd suffixLength . T.drop prefixLength
  where
    prefixLength = T.length "/nix/store/this-is-a-fictional-hash-.......-"
    suffixLength = T.length ".drv"

-- * Github-specific

processLogsForGithub :: RawLogs -> Text
processLogsForGithub (RawLogs l) =
  "Last 100 lines of logs:\n"
    <> "```\n"
    <> T.unlines (reverse $ take 100 $ reverse $ fmap limitLine $ T.lines $ processMessage l)
    <> "```\n"
  where
    limitLine ln
      | T.length ln > 650 = T.take 649 ln <> "…"
      | otherwise = ln
