module Garnix.Monad.Async where

import Control.Concurrent (forkFinally, forkIO, newEmptyMVar, newMVar, putMVar, readMVar)
import Control.Exception (throwIO)
import Control.Monad.Trans.Control (control)
import Garnix.Async
import Garnix.Duration
import Garnix.Monad (M, log, logError, runM, throw)
import Garnix.Prelude
import Garnix.Types (Error, Severity (..))

spawn :: M a -> M (Promise a)
spawn action = do
  env <- ask
  mvar <- liftIO newEmptyMVar
  let go r = putMVar mvar $ case r of
        Left exception -> PromiseException exception
        Right (Left err) -> PromiseThrew err
        Right (Right val) -> PromiseSucceeded val
  _ <- liftIO $ forkFinally (runM env action) go
  pure $ Promise mvar

resolve :: Promise a -> M a
resolve p =
  liftIO (resolveIO p) >>= \case
    PromiseException e -> liftIO $ throwIO e
    PromiseThrew e -> throwError e
    PromiseSucceeded a -> pure a

emptyPromise :: M (Promise ())
emptyPromise = do
  Promise <$> liftIO (newMVar $ PromiseSucceeded ())

logPromiseErrors :: (Show a) => Promise a -> M ()
logPromiseErrors (Promise mvar) = do
  control $ \runInBase -> do
    void $ forkIO $ do
      result <- readMVar mvar
      void $ runInBase $ case result of
        PromiseException exception -> log Error (show exception)
        PromiseThrew e -> logError e
        PromiseSucceeded _ -> pure ()
    pure $ Right ()

timeoutThrowing :: Duration -> Error -> M a -> M a
timeoutThrowing delay error action = do
  result <- timeout delay action
  case result of
    Just a -> pure a
    Nothing -> Garnix.Monad.throw error

joinAll_ :: [Promise a] -> M (Promise ())
joinAll_ rs = liftIO $ do
  mvar <- liftIO newEmptyMVar
  _ <- forkFinally (mapM resolveIO rs) (putMVar mvar . either PromiseException sequence_)
  pure $ Promise mvar

joinAll :: [Promise a] -> M (Promise [a])
joinAll promises = liftIO $ do
  mvar <- liftIO newEmptyMVar
  _ <- forkFinally (mapM resolveIO promises) (putMVar mvar . either PromiseException sequence)
  pure $ Promise mvar

-- | Like async's forConcurrently, but does not cancel if any action throws
doAllConcurrently :: [a] -> (a -> M b) -> M (Promise ())
doAllConcurrently v act = do
  promises <- forM v $ spawn . act
  joinAll_ promises
