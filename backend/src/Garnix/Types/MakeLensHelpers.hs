module Garnix.Types.MakeLensHelpers where

import Control.Lens
import Data.Char
import Data.List
import Language.Haskell.TH
import Prelude

externalTypes :: String -> LensRules
externalTypes prefix =
  lensRules
    & createClass .~ True
    & lensField .~ dropFieldPrefix prefix

dropFieldPrefix :: String -> FieldNamer
dropFieldPrefix prefix _tyName _fields field =
  let fieldPart = case stripPrefix prefix (nameBase field) of
        Nothing -> error ("field " <> nameBase field <> " doesn't start with " <> prefix)
        Just (_head %~ toLower -> field) ->
          if field == "type" then "type_" else field
      methodName =
        MethodName
          (mkName $ "Has" ++ (fieldPart & _head %~ toUpper))
          (mkName fieldPart)
   in [methodName]
