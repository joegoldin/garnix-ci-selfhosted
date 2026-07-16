-- | Self-host operator monitoring: instance stats (garnix's own Prometheus),
-- host stats (node-exporter), and running/pending job counts + recent build
-- durations (DB). One authed + self-host + admin endpoint that aggregates
-- everything so the web UI makes a single call. Refuses outside self-host.
module Garnix.API.Monitoring
  ( MonitoringAPI (..),
    monitoringAPI,
    MonitoringDto (..),
    InstanceStats (..),
    HostStats (..),
    JobStats (..),
    RecentBuild (..),
  )
where

import Control.Lens
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import Garnix.API.Admin (requireAdmin)
import Garnix.DB qualified as DB
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import Network.Wreq qualified as Wreq
import Servant.Auth.Server

data MonitoringAPI route = MonitoringAPI
  { _monitoringAPIGet :: route :- Get '[JSON] MonitoringDto
  }
  deriving (Generic)

monitoringAPI :: AuthResult AuthJwtPayload -> MonitoringAPI (AsServerT M)
monitoringAPI auth =
  MonitoringAPI
    { _monitoringAPIGet = do
        requireSelfHostConfig auth
        garnixMetrics <- scrape =<< view #metricsScrapeUrl
        nodeMetrics <- scrape =<< view #nodeExporterUrl
        (runningBuilds, pendingBuilds, runningRuns, pendingRuns) <- DB.getJobCounts
        recent <- DB.getRecentBuildDurations 10
        pure
          MonitoringDto
            { _monitoringDtoInstance =
                InstanceStats
                  { _instanceStatsEvalQueueLen = look "garnix_server_eval_queue_len" garnixMetrics,
                    _instanceStatsS3QueueLen = look "garnix_server_s3_queue_len" garnixMetrics,
                    _instanceStatsFodQueueLen = look "garnix_server_fod_check_queue_len" garnixMetrics,
                    _instanceStatsPackageBuildsAttempted = look "garnix_server_package_builds_attempted" garnixMetrics,
                    _instanceStatsCachePushSuccess = look "garnix_server_cache_push_success" garnixMetrics,
                    _instanceStatsCachePushFailure = look "garnix_server_cache_push_failure" garnixMetrics,
                    _instanceStatsScraped = not (Map.null garnixMetrics)
                  },
              _monitoringDtoHost =
                let memTotal = look "node_memory_MemTotal_bytes" nodeMetrics
                    memAvail = look "node_memory_MemAvailable_bytes" nodeMetrics
                 in HostStats
                      { _hostStatsLoad1 = look "node_load1" nodeMetrics,
                        _hostStatsLoad5 = look "node_load5" nodeMetrics,
                        _hostStatsLoad15 = look "node_load15" nodeMetrics,
                        _hostStatsMemTotalBytes = memTotal,
                        _hostStatsMemUsedBytes = (-) <$> memTotal <*> memAvail,
                        _hostStatsDiskTotalBytes = lookLabelled "node_filesystem_size_bytes" "mountpoint" "/" nodeMetrics,
                        _hostStatsDiskAvailBytes = lookLabelled "node_filesystem_avail_bytes" "mountpoint" "/" nodeMetrics,
                        _hostStatsCpuCount = countCpus nodeMetrics,
                        _hostStatsScraped = not (Map.null nodeMetrics)
                      },
              _monitoringDtoJobs =
                JobStats
                  { _jobStatsRunningBuilds = runningBuilds,
                    _jobStatsPendingBuilds = pendingBuilds,
                    _jobStatsRunningRuns = runningRuns,
                    _jobStatsPendingRuns = pendingRuns,
                    _jobStatsRecentBuilds =
                      map (\(name, status, secs) -> RecentBuild name (statusToText <$> status) secs) recent
                  }
            }
    }

statusToText :: Status -> Text
statusToText = \case
  Success -> "Success"
  Failure -> "Failure"
  Timeout -> "Timeout"
  Cancelled -> "Cancelled"

-- | GET a Prometheus text-exposition endpoint and parse it into a name->value
-- map. On any failure (unreachable, non-200, parse) returns an empty map, so
-- the page degrades gracefully to "not scraped" rather than erroring.
scrape :: Text -> M (Map Text Double)
scrape url =
  ( do
      resp <- withWreqOptions $ \opts -> liftIO (Wreq.getWith opts (cs url))
      pure $ parseProm (cs (resp ^. Wreq.responseBody))
  )
    `catchAny` const (pure Map.empty)

-- | Parse un-labelled prometheus samples (`metric_name <value>`) into a map,
-- keeping labelled lines under a synthetic key `name{labels}` for
-- 'lookLabelled'.
parseProm :: Text -> Map Text Double
parseProm =
  Map.fromList
    . catMaybes
    . map parseLine
    . filter (not . ("#" `T.isPrefixOf`))
    . T.lines
  where
    parseLine l = case T.words (T.strip l) of
      [name, val] -> (,) name <$> readDouble val
      _ -> Nothing
    readDouble t = case reads (cs t) of
      [(d, "")] -> Just d
      _ -> Nothing

look :: Text -> Map Text Double -> Maybe Double
look = Map.lookup

-- | Look up a labelled sample by a single label=value, tolerating other labels
-- in any order: matches lines whose metric key is
-- `name{...<label>="<value>"...}`.
lookLabelled :: Text -> Text -> Text -> Map Text Double -> Maybe Double
lookLabelled name label value m =
  listToMaybe
    [ v
    | (k, v) <- Map.toList m,
      (name <> "{") `T.isPrefixOf` k,
      (label <> "=\"" <> value <> "\"") `T.isInfixOf` k
    ]

countCpus :: Map Text Double -> Maybe Double
countCpus m =
  case length [k | k <- Map.keys m, "node_cpu_seconds_total{" `T.isPrefixOf` k, "mode=\"idle\"" `T.isInfixOf` k] of
    0 -> Nothing
    n -> Just (fromIntegral n)

data MonitoringDto = MonitoringDto
  { _monitoringDtoInstance :: InstanceStats,
    _monitoringDtoHost :: HostStats,
    _monitoringDtoJobs :: JobStats
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON MonitoringDto where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

data InstanceStats = InstanceStats
  { _instanceStatsEvalQueueLen :: Maybe Double,
    _instanceStatsS3QueueLen :: Maybe Double,
    _instanceStatsFodQueueLen :: Maybe Double,
    _instanceStatsPackageBuildsAttempted :: Maybe Double,
    _instanceStatsCachePushSuccess :: Maybe Double,
    _instanceStatsCachePushFailure :: Maybe Double,
    _instanceStatsScraped :: Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON InstanceStats where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

data HostStats = HostStats
  { _hostStatsLoad1 :: Maybe Double,
    _hostStatsLoad5 :: Maybe Double,
    _hostStatsLoad15 :: Maybe Double,
    _hostStatsMemTotalBytes :: Maybe Double,
    _hostStatsMemUsedBytes :: Maybe Double,
    _hostStatsDiskTotalBytes :: Maybe Double,
    _hostStatsDiskAvailBytes :: Maybe Double,
    _hostStatsCpuCount :: Maybe Double,
    _hostStatsScraped :: Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON HostStats where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

data JobStats = JobStats
  { _jobStatsRunningBuilds :: Int64,
    _jobStatsPendingBuilds :: Int64,
    _jobStatsRunningRuns :: Int64,
    _jobStatsPendingRuns :: Int64,
    _jobStatsRecentBuilds :: [RecentBuild]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON JobStats where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

data RecentBuild = RecentBuild
  { _recentBuildName :: Text,
    _recentBuildStatus :: Maybe Text,
    _recentBuildDurationSecs :: Double
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON RecentBuild where
  toEncoding = ourToEncoding
  toJSON = ourToJSON

-- | Throw 'Unauthorized' unless self-host mode is on and the caller is an admin.
requireSelfHostConfig :: AuthResult AuthJwtPayload -> M ()
requireSelfHostConfig auth = do
  selfHost <- view #selfHostMode
  unless selfHost $ throw Unauthorized
  requireAdmin auth
