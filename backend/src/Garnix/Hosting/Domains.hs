-- | Classification and validation of the extra hostnames a hosted server
-- declares (garnix.yaml @servers[].domains@ / the Configure registry).
--
-- A declared FQDN is either *wildcard-covered* — a strict subdomain of a known
-- base domain (the default hosting domain, an operator-configured extra base,
-- or a verified connected domain), which the existing wildcard DNS + Caddy
-- on-demand TLS already cover — or a *bare custom domain*, which the user must
-- point at the garnix host themselves (A/CNAME). Either way the backend emits an
-- explicit Traefik router and an on-demand-TLS allow-entry for it.
module Garnix.Hosting.Domains
  ( DomainKind (..),
    knownBaseDomains,
    classifyDomain,
    validateServerDomains,
  )
where

import Data.Text qualified as T
import Garnix.DB qualified as DB
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types (Error (OtherError))

data DomainKind
  = -- | A strict subdomain of the given known base — no per-server DNS needed.
    WildcardCovered Text
  | -- | Under no known base — needs a user-supplied A/CNAME record.
    BareCustom
  deriving stock (Eq, Show)

-- | All base domains under which any subdomain is wildcard-routed: the default
-- hosting domain, the operator's extra bases, and any verified connected domain.
knownBaseDomains :: M [Text]
knownBaseDomains = do
  base <- view #hostingDomain
  extra <- view #extraHostingDomains
  connected <- DB.getVerifiedConnectedDomains
  pure (base : extra <> connected)

-- | Classify a declared FQDN against the known bases.
classifyDomain :: [Text] -> Text -> DomainKind
classifyDomain bases fqdn =
  case filter (\b -> ("." <> b) `T.isSuffixOf` fqdn && fqdn /= b) bases of
    (b : _) -> WildcardCovered b
    [] -> BareCustom

-- | Reject a deploy whose declared domains collide with those already claimed
-- by another live server.
validateServerDomains :: [Text] -> M ()
validateServerDomains declared = do
  taken <- DB.getAllDeclaredServerDomains
  let clashes = filter (`elem` taken) declared
  unless (null clashes)
    $ throw
    $ OtherError
    $ "Domain(s) already in use by another server: " <> T.intercalate ", " clashes
