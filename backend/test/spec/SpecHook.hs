module SpecHook where

import Cradle
import GHC.Conc (getNumProcessors, setNumCapabilities)
import Garnix.API.Cache.Auth qualified
import Garnix.API.Cache.Permissions qualified
import Garnix.ExpiringCache (clearCache)
import Garnix.Prelude
import Test.Hspec

hook :: Spec -> Spec
hook spec =
  beforeAll_ setTestSshKeyPermissions
    $ before_
      ( clearCache Garnix.API.Cache.Permissions.__getRepoPermissionsCache
          >> clearCache Garnix.API.Cache.Auth.__accessTokenValidCache
      )
    $ do
      runIO (getNumProcessors >>= setNumCapabilities)
      spec

setTestSshKeyPermissions :: IO ()
setTestSshKeyPermissions = do
  run_
    $ cmd "chmod"
    & addArgs
      [ "go-rwx" :: String,
        "dev-action-runner-ssh-key"
      ]
