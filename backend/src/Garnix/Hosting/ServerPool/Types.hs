module Garnix.Hosting.ServerPool.Types where

import Garnix.Prelude

-- | MicroVM sizes, named @i<vcpu>x<GiB>@. Configured per-server in garnix.yaml
-- via @deployment.machine@; the provisioner allocates 'tierResources'.
data ServerTier
  = I1x1
  | I1x2
  | I2x2
  | I2x3
  | I2x4
  | I4x2
  | I4x4
  | I4x8
  | I8x8
  | I8x16
  | I16x16
  | I16x32
  deriving (Eq, Show, Enum, Bounded, Ord)

-- | The tier a server gets when garnix.yaml omits @deployment.machine@. i1x2
-- (2 GiB) rather than i1x1 (1 GiB): the shared guest profile plus a repo
-- activation can exhaust a 1-GiB guest during switch-to-configuration
-- (virtio-fs then returns ENOMEM).
instance Default ServerTier where
  def = I1x2

instance PGParameter "text" ServerTier where
  pgEncode proxy tier = pgEncode proxy (serverTierToText tier)

instance PGColumn "text" ServerTier where
  pgDecode proxy value =
    let text :: Text = pgDecode proxy value
     in case lookup text (map swap serverTierTextMapping) of
          Just tier -> tier
          Nothing -> error $ "Impossible: unknown server tier " <> cs text

serverTierTextMapping :: [(ServerTier, Text)]
serverTierTextMapping = map (\tier -> (tier, serverTierToText tier)) [minBound .. maxBound]

serverTierToText :: ServerTier -> Text
serverTierToText = \case
  I1x1 -> "i1x1"
  I1x2 -> "i1x2"
  I2x2 -> "i2x2"
  I2x3 -> "i2x3"
  I2x4 -> "i2x4"
  I4x2 -> "i4x2"
  I4x4 -> "i4x4"
  I4x8 -> "i4x8"
  I8x8 -> "i8x8"
  I8x16 -> "i8x16"
  I16x16 -> "i16x16"
  I16x32 -> "i16x32"

-- | vCPU count and memory (MiB) the microVM provisioner allocates for a tier.
-- The tier names encode vCPUxGiB.
tierResources :: ServerTier -> (Int, Int)
tierResources = \case
  I1x1 -> (1, 1024)
  I1x2 -> (1, 2048)
  I2x2 -> (2, 2048)
  I2x3 -> (2, 3072)
  I2x4 -> (2, 4096)
  I4x2 -> (4, 2048)
  I4x4 -> (4, 4096)
  I4x8 -> (4, 8192)
  I8x8 -> (8, 8192)
  I8x16 -> (8, 16384)
  I16x16 -> (16, 16384)
  I16x32 -> (16, 32768)

tierVcpus :: ServerTier -> Int
tierVcpus = fst . tierResources

tierMiB :: ServerTier -> Int
tierMiB = snd . tierResources

-- | Total resources committed across some set of guests. Used to weigh a
-- prospective new guest against the hosting budget.
data Committed = Committed {committedVcpus :: Int, committedMiB :: Int}
  deriving (Eq, Show)

instance Semigroup Committed where
  Committed a b <> Committed c d = Committed (a + c) (b + d)

instance Monoid Committed where
  mempty = Committed 0 0

-- | Count-weighted sum of tier resources: @[(tier, howMany)]@.
sumTierResources :: [(ServerTier, Int)] -> Committed
sumTierResources =
  foldMap (\(tier, n) -> Committed (tierVcpus tier * n) (tierMiB tier * n))

-- | Resolved (absolute) hosting budget caps. 'Nothing' in a dimension means
-- unbounded there (the legacy behaviour when no budget is configured).
data ResourceBudget = ResourceBudget
  { budgetVcpus :: Maybe Int,
    budgetMiB :: Maybe Int
  }
  deriving (Eq, Show)

-- | Would adding one guest of this tier keep BOTH dimensions within their
-- caps? An unset (Nothing) cap always fits that dimension.
fitsBudget :: ResourceBudget -> Committed -> ServerTier -> Bool
fitsBudget (ResourceBudget capV capM) (Committed v m) tier =
  within capV (v + tierVcpus tier) && within capM (m + tierMiB tier)
  where
    within Nothing _ = True
    within (Just cap) x = x <= cap
