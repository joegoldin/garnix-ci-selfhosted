module Garnix.Hosting.ServerPool.Types where

import Garnix.MonetaryCost
import Garnix.Prelude

data ServerTier
  = I2x4
  | I4x8
  | I8x16
  | I16x32
  deriving (Eq, Show, Enum, Bounded, Ord)

instance Default ServerTier where
  def = I2x4

instance PGParameter "text" ServerTier where
  pgEncode proxy tier = pgEncode proxy (serverTierToText tier)

instance PGColumn "text" ServerTier where
  pgDecode proxy value =
    let text :: Text = pgDecode proxy value
     in case lookup text (map swap serverTierTextMapping) of
          Just tier -> tier
          Nothing -> error $ "Impossible: unknown subscription type " <> cs text

serverTierTextMapping :: [(ServerTier, Text)]
serverTierTextMapping = map (\tier -> (tier, serverTierToText tier)) [minBound .. maxBound]

serverTierToText :: ServerTier -> Text
serverTierToText = \case
  I2x4 -> "i2x4"
  I4x8 -> "i4x8"
  I8x16 -> "i8x16"
  I16x32 -> "i16x32"

serverTierToHetznerServerType :: ServerTier -> [HetznerServerType]
serverTierToHetznerServerType = \case
  I2x4 -> [HetznerCX23, HetznerCPX22]
  I4x8 -> [HetznerCX33]
  I8x16 -> [HetznerCX43]
  I16x32 -> [HetznerCX53]

-- | See https://docs.hetzner.com/cloud/servers/overview/.
data HetznerServerType
  = HetznerCX23
  | HetznerCPX22
  | HetznerCX33
  | HetznerCX43
  | HetznerCX53
  deriving (Eq, Show, Enum, Bounded, Ord)

hetznerServerTypeToName :: HetznerServerType -> Text
hetznerServerTypeToName = \case
  HetznerCX23 -> "cx23"
  HetznerCPX22 -> "cpx22"
  HetznerCX33 -> "cx33"
  HetznerCX43 -> "cx43"
  HetznerCX53 -> "cx53"

data HetznerLocation
  = HetznerHelsinki
  | HetznerNuremberg
  | HetznerFalkenstein
  deriving (Eq, Show, Enum, Bounded, Ord)

hetznerLocationToName :: HetznerLocation -> Text
hetznerLocationToName = \case
  HetznerNuremberg -> "nbg1"
  HetznerFalkenstein -> "fsn1"
  HetznerHelsinki -> "hel1"

serverTierIncludedWithPlans :: ServerTier
serverTierIncludedWithPlans = I2x4

serverTierToCost :: ServerTier -> MonetaryCost
serverTierToCost = \case
  I2x4 -> usd 15
  I4x8 -> usd 30
  I8x16 -> usd 60
  I16x32 -> usd 120
