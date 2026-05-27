module Main (main) where

import Autodocodec.Yaml
import Data.Text.IO qualified as T
import Garnix.Prelude
import Garnix.YamlConfig

main :: IO ()
main = do
  T.putStr $ renderPlainSchemaViaCodec @GarnixConfig
