module Garnix.API.ConfigSchema (garnixConfigJsonSchema) where

import Autodocodec.Schema (JSONSchema, jsonSchemaViaCodec)
import Garnix.YamlConfig (GarnixConfig)

garnixConfigJsonSchema :: JSONSchema
garnixConfigJsonSchema = jsonSchemaViaCodec @GarnixConfig
