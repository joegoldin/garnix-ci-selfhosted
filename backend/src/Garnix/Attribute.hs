{-# LANGUAGE TemplateHaskell #-}

module Garnix.Attribute where

import Data.Text qualified as T
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import Garnix.YamlConfig

-- | An attribute is something like '.#nixosConfigurations.container'.
data Attribute = Attribute
  { _attributePackageType :: PackageType,
    _attributeSystem :: Maybe System,
    _attributePackageName :: Maybe PackageName,
    _attributeExtension :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)

makeFields ''Attribute

-- In time the '.' component should also be part of the `Attribute`. But
-- for now we don't use anything other than '.'
localAttr :: FlakeDir -> Attribute -> M Text
localAttr flakeDir attr = do
  flakeDir' <- safeGetAbsoluteFlakeDir flakeDir
  pure $ cs flakeDir' <> "#" <> review asAttribute attr

(<.>) :: Text -> Text -> Text
a <.> b = a <> "." <> b

-- Attrs that we want to build the subAttrs of
allParentAttrs :: [Attribute]
allParentAttrs =
  [ homeConfigurationsAttr,
    darwinConfigurationsAttr,
    nixosConfigurationsAttr
  ]
    <> [ typ sys
         | typ <- [packagesAttr, checksAttr, devShellsAttr],
           sys <- supportedSystems
       ]

-- Attrs that we want to build directly. They may, however, not exist
allDirectAttrs :: [Attribute]
allDirectAttrs =
  [typ sys | typ <- [defaultDevShellAttr, defaultPackageAttr], sys <- supportedSystems]

addNixosExtension :: Attribute -> Attribute
addNixosExtension attr
  | attr ^. packageType == TypeHomeConfiguration =
      attr & extension ?~ "activationPackage"
  | attr ^. packageType == TypeDarwinConfiguration =
      attr & extension ?~ "config.system.build.toplevel"
  | attr ^. packageType == TypeNixosConfiguration =
      attr & extension ?~ "config.system.build.toplevel"
  | otherwise = attr

homeConfigurationsAttr :: Attribute
homeConfigurationsAttr = attrPT TypeHomeConfiguration

darwinConfigurationsAttr :: Attribute
darwinConfigurationsAttr = attrPT TypeDarwinConfiguration

nixosConfigurationsAttr :: Attribute
nixosConfigurationsAttr = attrPT TypeNixosConfiguration

packageAttr :: System -> PackageName -> Attribute
packageAttr sys n = packagesAttr sys & packageName ?~ n

packagesAttr :: System -> Attribute
packagesAttr sys = attrPT TypePackage & system ?~ sys

checkAttr :: System -> PackageName -> Attribute
checkAttr sys n = checksAttr sys & packageName ?~ n

checksAttr :: System -> Attribute
checksAttr sys = attrPT TypeCheck & system ?~ sys

devShellAttr :: System -> PackageName -> Attribute
devShellAttr sys n = devShellsAttr sys & packageName ?~ n

devShellsAttr :: System -> Attribute
devShellsAttr sys = attrPT TypeDevShell & system ?~ sys

defaultDevShellAttr :: System -> Attribute
defaultDevShellAttr sys =
  attrPT TypeDefaultDevShell
    & system
    ?~ sys
    -- See Note [Nothing vs "" in packageName]
    & packageName
    ?~ ""

defaultPackageAttr :: System -> Attribute
defaultPackageAttr sys =
  attrPT TypeDefaultPackage
    & system
    ?~ sys
    -- See Note [Nothing vs "" in packageName]
    & packageName
    ?~ ""

overallAttr :: Attribute
overallAttr = attrPT TypeOverall

attribute :: Build -> Attribute
attribute build =
  Attribute
    (build ^. packageType)
    (build ^. system . maybeSystemIso)
    (Just $ build ^. package)
    Nothing

addSubAttr :: Attribute -> Text -> Maybe Attribute
addSubAttr attr sub = (review asAttribute attr <.> sub) ^? asAttribute

asAttribute :: Prism' Text Attribute
asAttribute = prism there back
  where
    there (Attribute TypeOverall Nothing Nothing Nothing) = ""
    there (Attribute typ sys name' ext) =
      let addName att = case name' of
            Nothing -> att
            Just (PackageName n) -> att ++ [n]
          addExt att = case ext of
            Nothing -> att
            Just e -> att ++ [e]
       in T.intercalate "." . filter (not . T.null) . addExt . addName $ case (typ, sys) of
            (TypeHomeConfiguration, Just _) -> error "Can't convert home package with system"
            (TypeHomeConfiguration, Nothing) ->
              ["homeConfigurations"]
            (TypeDarwinConfiguration, Just _) -> error "Can't convert darwin package with system"
            (TypeDarwinConfiguration, Nothing) ->
              ["darwinConfigurations"]
            (TypeNixosConfiguration, Just _) -> error "Can't convert nixos package with system"
            (TypeNixosConfiguration, Nothing) ->
              ["nixosConfigurations"]
            (TypePackage, Nothing) -> error "Can't convert package with no system"
            (TypePackage, Just system') ->
              ["packages", system' ^. systemTextIso]
            (TypeCheck, Nothing) -> error "Can't convert check with no system"
            (TypeCheck, Just system') ->
              ["checks", system' ^. systemTextIso]
            (TypeDevShell, Nothing) -> error "Can't convert devShell with no system"
            (TypeDevShell, Just system') ->
              ["devShells", system' ^. systemTextIso]
            (TypeDefaultDevShell, Nothing) -> error "Can't convert devShell with no system"
            (TypeDefaultDevShell, Just system') ->
              ["devShell", system' ^. systemTextIso]
            (TypeDefaultPackage, Nothing) -> error "Can't convert devShell with no system"
            (TypeDefaultPackage, Just system') ->
              ["defaultPackage", system' ^. systemTextIso]
            (TypeApp, Nothing) -> error "Can't convert app with no system"
            (TypeApp, Just system') ->
              ["apps", system' ^. systemTextIso]
            (TypeOverall, _) -> error "Can't convert overall package"
    back i =
      let nameAndExt a x = case x of
            [] -> a
            [name'] -> a & packageName ?~ PackageName name'
            name' : r ->
              a
                & packageName
                ?~ PackageName name'
                & extension
                ?~ T.intercalate "." r
          ext a r = case r of
            [] -> a
            _ -> a & extension ?~ T.intercalate "." r
       in case T.splitOn "." i of
            [] -> Right overallAttr
            "homeConfigurations" : t ->
              Right $ homeConfigurationsAttr `nameAndExt` t
            "darwinConfigurations" : t ->
              Right $ darwinConfigurationsAttr `nameAndExt` t
            "nixosConfigurations" : t ->
              Right $ nixosConfigurationsAttr `nameAndExt` t
            "packages" : system' : t ->
              Right $ packagesAttr (system' ^. from systemTextIso) `nameAndExt` t
            "checks" : system' : t ->
              Right $ checksAttr (system' ^. from systemTextIso) `nameAndExt` t
            "devShells" : system' : t ->
              Right $ devShellsAttr (system' ^. from systemTextIso) `nameAndExt` t
            "defaultPackage" : system' : t ->
              Right $ defaultPackageAttr (system' ^. from systemTextIso) `ext` t
            "devShell" : system' : t ->
              Right $ defaultDevShellAttr (system' ^. from systemTextIso) `ext` t
            _ -> Left i

-- * Matching

matchesConfig :: Attribute -> GarnixConfig -> Maybe Branch -> Bool
matchesConfig attr cfg branch =
  any matchesBuildSection $ cfg ^. buildSections
  where
    matchesBuildSection buildSection =
      branchMatches buildSection
        && anyMatchAttr (buildSection ^. includeSection)
        && not (anyMatchAttr (buildSection ^. excludeSection))
    anyMatchAttr = (any . matches) attr
    branchMatches s = case (s ^. branchSection, branch) of
      (Nothing, _) -> True
      (a, b) -> a == b

-- | Check whether a child of the attribute *could* be matched by the config
--
-- Note that this doesn't take into account the excludes section.
mightMatchConfig :: Attribute -> GarnixConfig -> Bool
mightMatchConfig attr cfg =
  let includes = concatMap (^. includeSection) (cfg ^. buildSections)
   in any (\i -> attr `mightMatch` i) includes

matches :: Attribute -> AttributeMatcher -> Bool
matches attr matcher = case T.splitOn "." $ review asAttribute attr of
  [a, b, c] -> case matcher ^. thirdPart of
    Nothing -> False
    Just c' ->
      a
        `partMatches` (matcher ^. firstPart . to cs)
        && b
        `partMatches` (matcher ^. secondPart . to cs)
        && c
        `partMatches` cs c'
  [a, b] -> case matcher ^. thirdPart of
    Nothing ->
      a
        `partMatches` (matcher ^. firstPart . to cs)
        && b
        `partMatches` (matcher ^. secondPart . to cs)
    Just _ -> False
  _ -> False
  where
    partMatches :: Text -> Text -> Bool
    partMatches _ "*" = True
    partMatches attPart matchPart = attPart == matchPart

-- | Checks whether a attribute could have a child matched by a matchers
mightMatch :: Attribute -> AttributeMatcher -> Bool
mightMatch attr matcher = case T.splitOn "." $ review asAttribute attr of
  [a, b] -> case matcher ^. thirdPart of
    Nothing -> False
    Just _ ->
      a
        `partMatches` (matcher ^. firstPart . to cs)
        && b
        `partMatches` (matcher ^. secondPart . to cs)
  [a] -> case matcher ^. thirdPart of
    Nothing ->
      a `partMatches` (matcher ^. firstPart . to cs)
    Just _ -> False
  _ -> False
  where
    partMatches :: Text -> Text -> Bool
    partMatches _ "*" = True
    partMatches attPart matchPart = attPart == matchPart

-- * Helpers

attrPT :: PackageType -> Attribute
attrPT pt = Attribute pt Nothing Nothing Nothing

{- Note [Nothing vs "" in packageName]
   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
   We distinguish between Nothing and "" in packageName. The difference is
   that Nothing indicates that we don't know what the package name is. "" on
   the other hand indicates that there *is* no package name. So:

     defaultPackage.x86_64-linux ==> packageName is Just ""
     packages.x86_64-linux ==> packageName is Nothing

   This isn't perfect, since encoding it like this allows both forms to
   exist in the Attribute form, but not the Text form.
-}
