{-# OPTIONS_GHC -Wno-orphans #-}

module Garnix.Modules.SchemaSpec where

import Data.Aeson
import Data.String.Interpolate (i)
import Garnix.DB.ModuleValues qualified as ModuleValues
import Garnix.Modules.Schema
import Garnix.Monad
import Garnix.Prelude
import Garnix.TestHelpers
import Garnix.TestHelpers.Monad
import System.IO.Temp
import Test.Hspec
import Test.QuickCheck

basicSchema :: ModuleSchemaType -> ModuleSchema
basicSchema = ModuleSchema Nothing Nothing Nothing Nothing

spec :: Spec
spec = parallel $ describe "Modules.SchemaSpec" $ do
  let wrap = aroundM_ suppressLogsWhenPassing
  inM $ wrap $ describe "readModuleSchema" $ do
    let optionsToSchema :: String -> M ModuleSchema
        optionsToSchema options = do
          liftBaseOp (withSystemTempDirectory "garnix-test") $ \dir -> do
            liftIO
              $ writeFile
                (dir </> "flake.nix")
                [i|
                  {
                    outputs = { ... } :
                      let
                        lib = #{nixpkgsLib};
                      in
                      {
                        garnixModules.default = #{options};
                      };
                  }
                |]
            readModuleSchema dir

    it "works for modules with no options field" $ do
      schema <- optionsToSchema "{}"
      schema `shouldBeM` basicSchema (Submodule mempty)

    it "works for modules with empty options field" $ do
      schema <- optionsToSchema "{ options = {}; }"
      schema `shouldBeM` basicSchema (Submodule mempty)

    it "understands secret options" $ do
      schema <-
        optionsToSchema
          [i|
            {
              options.password = lib.mkOption {
                type = lib.types.str // { name = "encryptedSecret"; };
              };
            }
          |]
      schema `shouldBeM` basicSchema (Submodule $ "password" ~> basicSchema Secret)

    it "understands path options" $ do
      schema <-
        optionsToSchema
          [i|
            {
              options.src = lib.mkOption { type = lib.types.path; };
            }
          |]
      schema `shouldBeM` basicSchema (Submodule $ "src" ~> basicSchema Path)

    it "understands string options" $ do
      schema <-
        optionsToSchema
          [i|
            {
              options.foo = lib.mkOption { type = lib.types.str; };
            }
          |]
      schema `shouldBeM` basicSchema (Submodule $ "foo" ~> basicSchema Str)

    it "understands bool options" $ do
      schema <-
        optionsToSchema
          [i|
            {
              options.foo = lib.mkOption { type = lib.types.bool; };
            }
          |]
      schema `shouldBeM` basicSchema (Submodule $ "foo" ~> basicSchema Garnix.Modules.Schema.Bool)

    it "understands submodules" $ do
      schema <-
        optionsToSchema
          [i|
            {
              options.foo = lib.mkOption {
                type = lib.types.submodule {
                  options.bar = lib.mkOption { type = lib.types.str; };
                };
              };
            }
          |]
      schema `shouldBeM` basicSchema (Submodule $ "foo" ~> basicSchema (Submodule $ "bar" ~> basicSchema Str))

    it "understands lists of submodules" $ do
      schema <-
        optionsToSchema
          [i|
            {
              options.foo = lib.mkOption {
                type = lib.types.submodule [
                  { options.bar = lib.mkOption { type = lib.types.str; }; }
                  { options.baz = lib.mkOption { type = lib.types.path; }; }
                ];
              };
            }
          |]
      schema `shouldBeM` basicSchema (Submodule ("foo" ~> basicSchema (Submodule $ "bar" ~> basicSchema Str <> "baz" ~> basicSchema Path)))

    it "understands attrsOf" $ do
      schema <-
        optionsToSchema
          [i|
            {
              options.foo = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
              };
            }
          |]
      schema `shouldBeM` basicSchema (Submodule ("foo" ~> basicSchema (AttrsOf Str)))

    it "understands listOf" $ do
      schema <-
        optionsToSchema
          [i|
            {
              options.foo = lib.mkOption {
                type = lib.types.listOf lib.types.str;
              };
            }
          |]
      schema `shouldBeM` basicSchema (Submodule ("foo" ~> basicSchema (ListOf Str)))

    it "understands lib.type.package" $ do
      schema <-
        optionsToSchema
          [i|
            {
              options.foo = lib.mkOption {
                type = lib.types.package;
              };
            }
          |]
      schema `shouldBeM` basicSchema (Submodule $ "foo" ~> basicSchema Garnix.Modules.Schema.Package)

    it "understands nullOr" $ do
      schema <-
        optionsToSchema
          [i|
            {
              options.foo = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
              };
            }
          |]
      schema `shouldBeM` basicSchema (Submodule $ "foo" ~> basicSchema (NullOr Garnix.Modules.Schema.Str))

    it "understands lib.types.port" $ do
      schema <-
        optionsToSchema
          [i|
            {
              options.foo = lib.mkOption {
                type = lib.types.port;
              };
            }
          |]
      schema `shouldBeM` basicSchema (Submodule $ "foo" ~> basicSchema UnsignedInt16)

    describe "modules that are functions" $ do
      it "passes in `lib`" $ do
        schema <-
          optionsToSchema
            [i|
              { lib, ... } : {
                options.foo = lib.mkOption {
                  type = lib.types.attrsOf lib.types.str;
                };
              }
            |]
        schema `shouldBeM` basicSchema (Submodule $ "foo" ~> basicSchema (AttrsOf Str))

      it "passes in (an empty) `config`" $ do
        schema <-
          optionsToSchema
            [i|
              { config, ... } : {
                options.foo = lib.mkOption {
                  type = lib.types.attrsOf lib.types.str;
                };
              }
            |]
        schema `shouldBeM` basicSchema (Submodule $ "foo" ~> basicSchema (AttrsOf Str))

      it "does not complain about unused, unsupported parameters" $ do
        schema <-
          optionsToSchema
            [i|
              { unsupported, ... } : {
                options.foo = lib.mkOption {
                  type = lib.types.attrsOf lib.types.str;
                };
                config = {
                  foo = unsupported.bar;
                };
              }
            |]
        schema `shouldBeM` basicSchema (Submodule $ "foo" ~> basicSchema (AttrsOf Str))

      it "does complain about unsupported parameters that are used in `options`" $ do
        Left error <-
          try
            $ optionsToSchema
              [i|
              { unsupported, ... } : {
                options.foo = lib.mkOption {
                  type = unsupported.bar;
                };
              }
            |]
        cs (show error) `shouldContainM` "module argument not supported: unsupported"

      it "passes in options only when needed" $ do
        schema <-
          optionsToSchema
            [i|
              { lib } : {
                options.foo = lib.mkOption {
                  type = lib.types.attrsOf lib.types.str;
                };
              }
            |]
        schema `shouldBeM` basicSchema (Submodule $ "foo" ~> basicSchema (AttrsOf Str))

    describe "metadata" $ do
      it "unpacks description fields from options" $ do
        schema <-
          optionsToSchema
            [i|
                { lib } : {
                  options.foo = lib.mkOption {
                    type = lib.types.str;
                    description = "this is the description of foo";
                  };
                }
              |]
        schema
          `shouldBeM` basicSchema
            ( Submodule
                $ "foo"
                ~> (basicSchema Str)
                  { description = Just "this is the description of foo"
                  }
            )

      it "unpacks example fields from options" $ do
        schema <-
          optionsToSchema
            [i|
                { lib } : {
                  options.foo = lib.mkOption {
                    type = lib.types.str;
                    example = "some example value";
                  };
                }
              |]
        schema
          `shouldBeM` basicSchema
            ( Submodule
                $ "foo"
                ~> (basicSchema Str)
                  { example = Just "some example value"
                  }
            )

      it "unpacks description fields from submodules" $ do
        schema <-
          optionsToSchema
            [i|
              {
                options.foo = lib.mkOption {
                  type = lib.types.submodule [
                    { options.bar = lib.mkOption { type = lib.types.str; description = "bar desc"; }; }
                    { options.baz = lib.mkOption { type = lib.types.path; description = "baz desc"; }; }
                  ];
                };
              }
            |]
        schema
          `shouldBeM` basicSchema
            ( Submodule
                ( "foo"
                    ~> basicSchema
                      ( Submodule
                          $ "bar"
                          ~> (basicSchema Str)
                            { description = Just "bar desc"
                            }
                          <> "baz"
                          ~> (basicSchema Path)
                            { description = Just "baz desc"
                            }
                      )
                )
            )

      it "unpacks example fields from submodules" $ do
        schema <-
          optionsToSchema
            [i|
              {
                options.foo = lib.mkOption {
                  type = lib.types.submodule [
                    { options.bar = lib.mkOption { type = lib.types.str; example = "example value for bar"; }; }
                    { options.baz = lib.mkOption { type = lib.types.port; example = 1234; }; }
                  ];
                };
              }
            |]
        schema
          `shouldBeM` basicSchema
            ( Submodule
                ( "foo"
                    ~> basicSchema
                      ( Submodule
                          $ "bar"
                          ~> (basicSchema Str)
                            { example = Just "example value for bar"
                            }
                          <> "baz"
                          ~> (basicSchema UnsignedInt16)
                            { example = Just "1234"
                            }
                      )
                )
            )

      describe "defaults" $ do
        let cases =
              [ ("str", "\"test default\"", Str, ModuleValues.NixString "test default"),
                ("int", "8080", Int, ModuleValues.NixInt 8080),
                ("bool", "false", Garnix.Modules.Schema.Bool, ModuleValues.NixBool False),
                -- using nix paths as defaults for path options is not a good
                -- idea, since they'll just point to some path relative to the
                -- option declaration. We should rather use strings.
                ("path", "\"./.\"", Path, ModuleValues.NixString "./.")
              ]
        forM_ cases $ \(nixOptionType :: Text, defaultValue :: Text, schemaType, foo) -> do
          it ("extracts defaults for " <> cs nixOptionType) $ do
            schema <-
              optionsToSchema
                [i|
                  {
                    options.foo = lib.mkOption {
                      type = lib.types.#{nixOptionType};
                      default = #{defaultValue};
                    };
                  }
                |]
            schema
              `shouldBeM` basicSchema
                ( Submodule
                    $ "foo"
                    ~> (basicSchema schemaType)
                      { default_ = Just foo
                      }
                )

        it "extracts defaults for null" $ do
          schema <-
            optionsToSchema
              [i|
                {
                  options.foo = lib.mkOption { type = lib.types.nullOr lib.types.int; default = null; };
                }
              |]
          schema
            `shouldBeM` basicSchema
              ( Submodule
                  $ "foo"
                  ~> (basicSchema (NullOr Int))
                    { default_ = Just ModuleValues.NixNull
                    }
              )

        it "extracts defaults for lists" $ do
          schema <-
            optionsToSchema
              [i|
                {
                  options.foo = lib.mkOption {
                    type = lib.types.listOf lib.types.int;
                    default = [ 1 2 3 ];
                  };
                }
              |]
          schema
            `shouldBeM` basicSchema
              ( Submodule
                  $ "foo"
                  ~> (basicSchema (ListOf Int))
                    { default_ = Just (ModuleValues.NixList $ fmap ModuleValues.NixInt [1, 2, 3])
                    }
              )

      it "extracts option names" $ do
        schema <-
          optionsToSchema
            [i|
                {
                  options.foo = lib.mkOption {
                    type = lib.types.listOf lib.types.int;
                  } // {
                    name = "test name";
                  };
                }
              |]
        schema
          `shouldBeM` basicSchema
            ( Submodule
                $ "foo"
                ~> (basicSchema (ListOf Int))
                  { name = Just "test name"
                  }
            )

      it "extracts description for the module from the flake description" $ do
        liftBaseOp (withSystemTempDirectory "garnix-test") $ \dir -> do
          liftIO
            $ writeFile
              (dir </> "flake.nix")
              [i|
                {
                  description = "test description";
                  outputs = { ... } : { garnixModules.default = {}; };
                }
              |]
          schema <- readModuleSchema dir
          description schema `shouldBeM` Just "test description"

  describe "json serialization" $ do
    it "roundtrips" $ do
      property $ \(schema :: ModuleSchema) ->
        eitherDecode' (encode schema) `shouldBe` Right schema

instance Arbitrary ModuleSchema where
  arbitrary = ModuleSchema <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary
  shrink = const []

instance Arbitrary ModuleSchemaType where
  arbitrary =
    sized $ \size -> case size of
      0 ->
        oneof
          [ pure Secret,
            pure Path,
            pure Str,
            pure Garnix.Modules.Schema.Bool,
            pure Garnix.Modules.Schema.Int,
            pure UnsignedInt16,
            Garnix.Modules.Schema.Enum <$> arbitrary,
            pure Garnix.Modules.Schema.Package
          ]
      _ -> do
        let smaller = size `div` 2
        oneof
          [ Submodule . fmap basicSchema <$> resize smaller arbitrary,
            AttrsOf <$> resize smaller arbitrary,
            ListOf <$> resize smaller arbitrary,
            NullOr <$> resize smaller arbitrary
          ]
  shrink = \case
    Secret -> []
    Path -> []
    Str -> []
    NonEmptyStr -> []
    Garnix.Modules.Schema.Bool -> []
    Garnix.Modules.Schema.Int -> []
    UnsignedInt16 -> []
    Garnix.Modules.Schema.Enum variants -> map Garnix.Modules.Schema.Enum (shrink variants)
    ListOf inner -> [inner]
    AttrsOf inner -> [inner]
    Garnix.Modules.Schema.Package -> []
    NullOr inner -> [inner]
    Submodule innerSchema ->
      let inner = typ <$> innerSchema
       in toList inner <> map Submodule (fmap basicSchema <$> shrink inner)

instance Arbitrary ModuleValues.NixValue where
  arbitrary =
    sized $ \size -> case size of
      0 -> oneof nonRecursive
      _ ->
        resize (size `div` 2)
          $ oneof
            ( nonRecursive
                <> [ ModuleValues.NixList <$> arbitrary,
                     ModuleValues.NixSet <$> arbitrary
                   ]
            )
    where
      nonRecursive =
        [ ModuleValues.NixString <$> arbitrary,
          ModuleValues.NixPath <$> arbitrary,
          ModuleValues.NixRaw <$> arbitrary,
          ModuleValues.NixBool <$> arbitrary,
          ModuleValues.NixInt <$> arbitrary,
          pure ModuleValues.NixNull
        ]
  shrink = \case
    ModuleValues.NixList list -> fmap ModuleValues.NixList (shrink list)
    ModuleValues.NixSet set -> fmap ModuleValues.NixSet (shrink set)
    _ -> []

instance Arbitrary ModuleValues.NixIdentifier where
  arbitrary = ModuleValues.NixIdentifier <$> arbitrary
  shrink (ModuleValues.NixIdentifier s) = fmap ModuleValues.NixIdentifier (shrink s)
