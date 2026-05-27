module Garnix.MonetaryCost
  ( MonetaryCost,
    usd,
    formatCost,
    roundFromUsd,
    getCostInCents,
    addCost,
    multiplyCost,
    divCost,
  )
where

import Garnix.Prelude

newtype MonetaryCost = MonetaryCost {getCostInCents :: Int32}
  deriving stock (Eq, Show, Generic, Ord)
  deriving newtype (ToJSON, FromJSON)

formatCost :: MonetaryCost -> Text
formatCost (MonetaryCost costInCents) = "$" <> show dollars <> "." <> centsFormatted
  where
    (dollars, cents) = costInCents `divMod` 100
    centsFormatted
      | 0 <= cents && cents <= 9 = "0" <> show cents
      | 10 <= cents && cents <= 99 = show cents
      | otherwise = error "Impossible cents value"

usd :: Int32 -> MonetaryCost
usd dollars = MonetaryCost $ dollars * 100

roundFromUsd :: Double -> MonetaryCost
roundFromUsd dollars = MonetaryCost $ round $ dollars * 100

addCost :: MonetaryCost -> MonetaryCost -> MonetaryCost
addCost (MonetaryCost a) (MonetaryCost b) = MonetaryCost (a + b)

multiplyCost :: (Real a) => MonetaryCost -> a -> MonetaryCost
multiplyCost (MonetaryCost costInCents) multiplier = roundFromUsd $ fromIntegral costInCents * realToFrac multiplier / 100.0

divCost :: MonetaryCost -> MonetaryCost -> Int32
a `divCost` b = getCostInCents a `quot` getCostInCents b
