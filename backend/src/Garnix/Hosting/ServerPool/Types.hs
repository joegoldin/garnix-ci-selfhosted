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

instance Default ServerTier where
  def = I1x1

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
