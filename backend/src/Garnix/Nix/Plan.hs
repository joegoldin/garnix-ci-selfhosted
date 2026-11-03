module Garnix.Nix.Plan
  ( getPlanOf,
    _parsePlanOutputs,
  )
where

import Cradle
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.ByteString (ByteString)
import Data.Char
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Tuple.Extra
import Garnix.Monad
import Garnix.Nix.StorePath (unwrapDerivations)
import Garnix.Nix.Types
import Garnix.NixConfig (addNixConfigEnvironment)
import Garnix.Prelude
import Garnix.Types hiding (head)

mapToStorePaths :: (ConvertibleStrings a Text) => [a] -> M [StorePath]
mapToStorePaths paths = forM paths $ either (throw . OtherError) pure . parseStorePath

mapToDrvPaths :: [Text] -> M [DrvPath]
mapToDrvPaths paths = map DrvPath <$> mapToStorePaths paths

-- Nix understands deferred, floating CA and versioned dynamic derivations;
-- nix-derivation rejects even a plain Derive with an empty output path.
-- Read the whole plan in one process rather than launching Nix per derivation.
getDrvOutputPaths :: [DrvPath] -> M [(DrvPath, [StorePath])]
getDrvOutputPaths [] = pure []
getDrvOutputPaths drvPaths = do
  nixConfig <- view #userNixConfig
  (StdoutTrimmed output, StderrRaw _, exit) <-
    run
      $ cmd "nix"
      & addArgs (["derivation", "show"] <> map cs drvPaths :: [Text])
      & addNixConfigEnvironment nixConfig
  case exit of
    ExitSuccess -> do
      paths <- aesonDecode "planned derivation outputs" _parsePlanOutputs output
      forM drvPaths $ \drv -> case Map.lookup drv paths of
        Just outputs -> pure (drv, outputs)
        Nothing -> throw $ OtherError $ "Missing planned derivation in Nix output: " <> cs drv
    ExitFailure _ -> throw $ OtherError "Could not read planned derivations with nix derivation show"

_parsePlanOutputs :: Aeson.Value -> Aeson.Parser (Map.Map DrvPath [StorePath])
_parsePlanOutputs value = do
  derivations :: Map.Map Text Aeson.Value <- parseJSON $ unwrapDerivations value
  Map.fromList
    <$> forM
      (Map.toList derivations)
      ( \(drv, definition) -> do
          drvPath <- either (fail . cs) pure $ parseDrvPath $ absolute drv
          outputs :: Map.Map Text Aeson.Value <- Aeson.withObject "derivation" (Aeson..: "outputs") definition
          paths <- traverse (Aeson.withObject "output" (Aeson..:? "path")) outputs
          known <- forM (filter (not . T.null) $ catMaybes $ Map.elems paths) $ \path ->
            either (fail . cs) pure $ parseStorePath $ absolute path
          pure (drvPath, known)
      )
  where
    absolute path = if "/" `T.isPrefixOf` path then path else "/nix/store/" <> path

getPlanOf :: ByteString -> M Plan
getPlanOf = mockable #getBuildPlanMock $ \input -> do
  (toBuild, remaining) <-
    firstM mapToDrvPaths
      . span ("/nix/store/" `T.isPrefixOf`)
      . fmap (T.dropWhile isSpace)
      . drop 1
      . dropWhile (not . isStartOfDerivationPaths)
      . T.lines
      . cs
      $ input
  when (not (null remaining) && not ("will be fetched" `T.isInfixOf` head remaining))
    $ log Critical "Expected `nix build --dry-run` to output a list of derivations to be built followed by optionally a list of derivations to be fetched"
  outputHashes <- getDrvOutputPaths toBuild
  pure $ Plan outputHashes

isStartOfDerivationPaths :: Text -> Bool
isStartOfDerivationPaths line
  | "derivations will be built:" `T.isSuffixOf` line = True
  | "derivation will be built:" `T.isSuffixOf` line = True
  | otherwise = False
