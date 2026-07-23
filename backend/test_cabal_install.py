import pathlib
import unittest


BACKEND = pathlib.Path(__file__).parent
ACTION_DEFINITION = BACKEND / "default.nix"
KEY_PATCH = BACKEND.parent / "nix/patches/cabal-install-hackage-root-key.patch"

RETIRED_HACKAGE_ROOT_KEY = (
    "be75553f3c7ba1dbe298da81f1d1b05c9d39dd8ed2616c9bddf1525ca8c03e48"
)
CURRENT_HACKAGE_ROOT_KEY = (
    "c7de58fc6a224b92b5b513f26fbb8b370f2d97c7cfe0075a951314a55734be93"
)
DREAMHOST_MIRROR = "objects-us-east-1.dream.io"


class CabalInstallTests(unittest.TestCase):
    def test_patch_rotates_the_embedded_hackage_root_key(self):
        text = KEY_PATCH.read_text()

        self.assertIn(f'-    "{RETIRED_HACKAGE_ROOT_KEY}"', text)
        self.assertIn(f'+    "{CURRENT_HACKAGE_ROOT_KEY}"', text)
        self.assertIn(f'uriRegName auth /= "{DREAMHOST_MIRROR}"', text)

    def test_backend_uses_the_patched_cabal_install(self):
        action_definition = ACTION_DEFINITION.read_text()

        self.assertIn(
            "cabalInstall = pkgs.haskellPackages.cabal-install.overrideAttrs",
            action_definition,
        )
        self.assertEqual(
            action_definition.count("pkgs.haskellPackages.cabal-install"),
            1,
        )
        self.assertGreaterEqual(action_definition.count("cabalInstall"), 3)
        self.assertNotIn("CABAL_CONFIG", action_definition)


if __name__ == "__main__":
    unittest.main()
