module SpecHook where

import Cradle
import GHC.Conc (getNumProcessors, setNumCapabilities)
import Garnix.API.Cache.Auth qualified
import Garnix.API.Cache.Permissions qualified
import Garnix.API.Hosts qualified
import Garnix.ExpiringCache (clearCache)
import Garnix.Prelude
import Test.Hspec

hook :: Spec -> Spec
hook spec =
  beforeAll_ setTestSshKeyPermissions
    $ before_
      ( clearCache Garnix.API.Cache.Permissions.__getRepoPermissionsCache
          >> clearCache Garnix.API.Cache.Auth.__accessTokenValidCache
          >> clearCache Garnix.API.Hosts.__onDemandDomainsCache
      )
    $ do
      runIO (getNumProcessors >>= setNumCapabilities)
      spec

setTestSshKeyPermissions :: IO ()
setTestSshKeyPermissions = do
  -- git can't store 0600 modes, so fresh checkouts have these keys 0644 and
  -- ssh refuses them ("UNPROTECTED PRIVATE KEY FILE"). ssh-key-for-tests is
  -- what the server-pool health check uses: with it 0644, pooled VMs never
  -- become ready and every deploy spec times out waiting for provisioning.
  run_
    $ cmd "chmod"
    & addArgs
      [ "go-rwx" :: String,
        "dev-action-runner-ssh-key",
        "ssh-key-for-tests"
      ]
