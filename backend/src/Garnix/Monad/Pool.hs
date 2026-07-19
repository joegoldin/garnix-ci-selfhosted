module Garnix.Monad.Pool (Pool, newPool, withPoolM, withPool) where

import Control.Concurrent.Lifted (MVar, modifyMVar, newEmptyMVar, newMVar, putMVar, takeMVar)
import Data.Generics.Product (HasField')
import Data.Sequence (Seq ((:<|)), (|>))
import Data.Sequence qualified as Seq
import Garnix.Monad.Metrics
import Garnix.Prelude
import System.Metrics.Prometheus.Metric.Gauge (Gauge, set)
import System.Metrics.Prometheus.Metric.Histogram (Histogram)

-- | A slot semaphore whose waiters are woken strictly in arrival order:
-- the oldest job gets the next free slot, regardless of which repo/owner it
-- belongs to. (Upstream garnix scheduled round-robin per key so no tenant
-- could starve the others; on a single-operator self-host that let newer
-- pushes under a different key jump ahead of older waiting jobs, so we use
-- plain FIFO instead. The key argument is kept in the API for callers but
-- does not affect scheduling.)
newtype FifoQSem = FifoQSem (MVar Queue)

data Queue
  = SlotsAvailable
      { count :: Int
      }
  | BackedUp
      { scheduled :: Seq (MVar ())
      }

newQSem :: Gauge -> Int -> IO FifoQSem
newQSem gauge initial = do
  let q = SlotsAvailable initial
  updateGauge gauge q
  sem <- newMVar q
  return (FifoQSem sem)

modifyAndUpdateGauge :: Gauge -> FifoQSem -> (Queue -> IO (Queue, output)) -> IO output
modifyAndUpdateGauge gauge (FifoQSem q) action = do
  modifyMVar q $ \queue -> do
    (newQueue, output) <- action queue
    updateGauge gauge newQueue
    pure (newQueue, output)

-- | The gauge is the number of waiters (0 when there are free slots; it used
-- to report free slots as a negative count, which made the queue-length
-- metrics read as nonsense).
updateGauge :: Gauge -> Queue -> IO ()
updateGauge g q = do
  flip set g $ realToFrac $ case q of
    SlotsAvailable _ -> 0 :: Int
    BackedUp seq -> length seq

waitQSem :: Gauge -> FifoQSem -> IO ()
waitQSem gauge q = do
  res <- schedule
  case res of
    Nothing -> pure ()
    Just me -> takeMVar me
  where
    schedule :: IO (Maybe (MVar ()))
    schedule = modifyAndUpdateGauge gauge q $ \queue -> do
      case queue of
        BackedUp {scheduled} -> do
          me <- newEmptyMVar
          pure (BackedUp {scheduled = scheduled |> me}, Just me)
        SlotsAvailable {count = 0} -> do
          me <- newEmptyMVar
          pure (BackedUp {scheduled = Seq.singleton me}, Just me)
        SlotsAvailable {count} -> do
          pure (SlotsAvailable (count - 1), Nothing)

signalQSem :: Gauge -> FifoQSem -> IO ()
signalQSem gauge q = do
  modifyAndUpdateGauge gauge q $ \queue -> do
    (,()) <$> case queue of
      SlotsAvailable {count} -> pure $ SlotsAvailable {count = count + 1}
      BackedUp {scheduled} -> do
        case scheduled of
          Seq.Empty -> pure $ SlotsAvailable {count = 1}
          -- Hand the freed slot directly to the oldest waiter.
          upNext :<| rest -> do
            putMVar upNext ()
            pure
              $ if Seq.null rest
                then SlotsAvailable {count = 0}
                else BackedUp {scheduled = rest}

data Pool a = Pool
  { _qsem :: FifoQSem,
    _timerMetric :: Lens' Metrics Histogram,
    _lenMetric :: Lens' Metrics Gauge
  }

newPool :: (MonadIO m) => Int -> Metrics -> Lens' Metrics Histogram -> Lens' Metrics Gauge -> m (Pool a)
newPool limit metrics timerMetric lenMetric = do
  qsem <- liftIO $ newQSem (metrics ^. lenMetric) limit
  pure $ Pool qsem timerMetric lenMetric

withPoolM :: (MonadMask m, MonadReader s m, HasField' "metrics" s Metrics, MonadIO m) => (s -> Pool a) -> a -> m b -> m b
withPoolM poolLens key action = do
  pool <- asks poolLens
  withPool pool key action

withPool :: (MonadMask m, MonadReader s m, HasField' "metrics" s Metrics, MonadIO m) => Pool a -> a -> m b -> m b
withPool (Pool qsem timerMetricLens lenMetricLens) _key action = do
  bracket_ acquire release action
  where
    acquire = do
      lenMetric <- view (#metrics . lenMetricLens)
      timingAs timerMetricLens $ liftIO $ waitQSem lenMetric qsem
    release = do
      lenMetric <- view (#metrics . lenMetricLens)
      liftIO $ signalQSem lenMetric qsem
