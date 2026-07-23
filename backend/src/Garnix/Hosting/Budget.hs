-- | Parsing and host-relative resolution of the hosting resource budgets
-- (total guest RAM and vCPUs). The NixOS module renders each budget as either
-- @total:<n>@ (absolute cap) or @reserve:<n>@ (leave <n> free on the host);
-- @resolveBudget@ turns a @reserve@ into an absolute cap using the host total.
module Garnix.Hosting.Budget
  ( BudgetSpec (..),
    parseBudget,
    resolveBudget,
    hostTotalMiB,
    hostVcpus,
  )
where

import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import GHC.Conc (getNumProcessors)
import Garnix.Prelude
import Text.Read (readMaybe)

-- | A budget as configured: either an absolute total or an amount to keep
-- free on the host. Units are MiB for memory, whole cores for cpu.
data BudgetSpec = Absolute Int | Reserve Int
  deriving (Eq, Show)

-- | Parse the env encoding @total:<n>@ / @reserve:<n>@. The number is already
-- in the backend's units (MiB / cores) — the NixOS module converts GiB->MiB
-- at render time.
parseBudget :: Text -> Maybe BudgetSpec
parseBudget s = case T.splitOn ":" (T.strip s) of
  ["total", n] -> Absolute <$> readMaybe (cs n)
  ["reserve", n] -> Reserve <$> readMaybe (cs n)
  _ -> Nothing

-- | Resolve to an absolute cap given the host total for that dimension.
-- 'Nothing' (unconfigured) stays unbounded; a reserve never goes negative.
resolveBudget :: Int -> Maybe BudgetSpec -> Maybe Int
resolveBudget _ Nothing = Nothing
resolveBudget _ (Just (Absolute a)) = Just a
resolveBudget hostTotal (Just (Reserve r)) = Just (max 0 (hostTotal - r))

-- | Host RAM in MiB, from @/proc/meminfo@'s @MemTotal@ (reported in kB).
hostTotalMiB :: IO Int
hostTotalMiB = do
  contents <- readFile "/proc/meminfo"
  let kb =
        listToMaybe
          [ n
            | line <- lines contents,
              ["MemTotal:", v, "kB"] <- [words line],
              Just n <- [readMaybe v]
          ]
  pure $ maybe 0 (`div` 1024) kb

-- | Number of host CPUs the RTS sees.
hostVcpus :: IO Int
hostVcpus = getNumProcessors
