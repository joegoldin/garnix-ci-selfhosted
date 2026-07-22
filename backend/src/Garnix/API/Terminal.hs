-- | In-app web terminal: an authenticated, ownership-gated WebSocket that
-- bridges an xterm.js client in the browser to a PTY running exactly
-- @ssh garnix\@\<guest\>@ for one of the user's own deployed servers.
--
-- Security posture (each point is deliberate, don't weaken casually):
--
--   * The route sits behind the same @Auth '[JWT, Cookie]@ as the rest of the
--     API: anything but an 'Authenticated' web session is rejected before any
--     upgrade happens, and nothing is ever spawned for it.
--   * Ownership is checked exactly like 'Garnix.API.Hosts.getServerStats':
--     the requested 'ServerId' must be among
--     'getRunningAndRecentServersForOwners' for the user's login + installed
--     orgs, otherwise 'NotFound'. Shell access additionally requires
--     'Garnix.Access.hasAccessToRepo' for the server's configuration build.
--     The guest IP is resolved from the DB row — never from anything
--     client-supplied.
--   * The spawned process is a fixed argv (no shell): @ssh@ with the hosting
--     key args from 'ServerPool.sshArgsFor' (the exact mechanism deploys use)
--     plus hardening flags (no agent/X11 forwarding, all forwardings
--     cleared), to @\<login user\>\@\<guest ip\>@. The login user defaults to
--     @garnix@; any override must both match a strict allowlist pattern and be
--     one of the guest's declared users, and @root@ is always refused. The
--     session identity is a short-lived certificate signed by the dedicated
--     terminal CA ('sshTerminalCaKey'), never by the hosting/deploy key. A
--     client-chosen override is passed as a single non-interpolated argv
--     element, never through a shell.
--     Everything else about the command is fixed server-side; the remaining
--     client-controlled inputs are terminal bytes (written to the PTY) and
--     resize dimensions (clamped).
--   * Browser cookie sessions are protected against cross-site WebSocket
--     hijacking: when an @Origin@ header is present it must match the
--     configured 'baseUrl' origin.
--   * Sessions are bounded: a per-user concurrency cap, an idle timeout and
--     an absolute duration limit. Cleanup tears down the PTY and the ssh
--     child (TERM, then KILL) on every exit path.
--   * Terminal content is never logged — lifecycle events only.
module Garnix.API.Terminal
  ( TerminalAPI (..),
    terminalAPI,

    -- * Exported for the spec
    TerminalTarget (..),
    signingArgs,
  )
where

import Control.Concurrent (MVar, modifyMVar, modifyMVar_)
import Control.Concurrent.Async (race)
import Control.Exception.Safe (throwString, tryAny)
import Data.Aeson qualified as Aeson
import Data.Char (isAsciiLower, isDigit)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map qualified as Map
import Data.Text qualified as T
import Data.UUID qualified
import Data.UUID.V4 qualified
import Garnix.Access (hasAccessToRepo)
import Garnix.DB qualified as DB
import Garnix.Duration
import Garnix.GithubInterface.Types (organizationName)
import Garnix.Hosting.Helpers
import Garnix.Hosting.ServerPool qualified as ServerPool
import Garnix.Monad
import Garnix.Prelude
import Garnix.Types
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Network.Wai.Handler.WebSockets qualified as WaiWs
import Network.WebSockets qualified as WS
import Servant.Auth.Server
import Servant.RawM (RawM)
import Servant.RawM.Server ()
import System.Directory (doesFileExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Pty qualified as Pty
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process (ProcessHandle, getPid, readProcessWithExitCode, terminateProcess, waitForProcess)
import System.Timeout (timeout)

data TerminalAPI route = TerminalAPI
  { -- | @?user=@ optionally selects the guest login user (default: garnix);
    -- see 'validateLoginUser' for the strict allowlist gate it must pass.
    _terminalAPIConnect :: route :- Capture "serverId" ServerId :> QueryParam "user" Text :> RawM
  }
  deriving (Generic)

terminalAPI :: AuthResult AuthJwtPayload -> TerminalAPI (AsServerT M)
terminalAPI auth = TerminalAPI {_terminalAPIConnect = connectTerminal auth}

-- * Limits (bounded by design; see module header)

maxSessionsPerUser :: Int
maxSessionsPerUser = 4

idleTimeout :: Duration
idleTimeout = fromMinutes @Int 10

maxSessionDuration :: Duration
maxSessionDuration = fromMinutes @Int 60

watchdogInterval :: Duration
watchdogInterval = fromSeconds @Int 5

-- | Per-frame and per-message cap on client websocket payloads (1 MiB); a
-- terminal only ever needs keystrokes and resize messages.
maxWsPayloadBytes :: Int64
maxWsPayloadBytes = 1024 * 1024

-- | Authenticate + authorize in 'M' (same monad, same checks as the rest of
-- the API), then hand back the WAI 'Application' that performs the websocket
-- upgrade. Every rejection happens before anything is spawned.
connectTerminal :: AuthResult AuthJwtPayload -> ServerId -> Maybe Text -> M Wai.Application
connectTerminal (Authenticated (WebSession user ghToken)) serverId requestedUser = do
  loginUser <- validateLoginUser requestedUser
  servers <-
    getRunningAndRecentServersForOwners
      . (GhRepoOwner (user ^. githubLogin) :)
      . map organizationName
      =<< getInstalledOrgs ghToken
  -- Ownership gate: same membership check as getServerStats/deleteHost.
  server <- case find ((== serverId) . _runningServerId) servers of
    Just server -> pure server
    Nothing -> do
      log Notice "terminal: websocket rejected (server not owned or unknown)"
      throw NotFound
  -- [H1] Repo-access gate: org membership alone is too coarse for a shell.
  -- The caller must also have access to the repo this server was deployed
  -- from (public repo, admin, or collaborator — the same 'hasAccessToRepo'
  -- the build/commit/artifact endpoints use). Publicity comes from the
  -- server's configuration build row, the same DB snapshot
  -- 'getBuildWithAccess' trusts, so connecting stays forge-round-trip-free.
  build <- DB.getBuild (_runningServerConfigurationBuildId server)
  hasAccess <-
    hasAccessToRepo
      (Just user)
      (build ^. repoIsPublic)
      (_runningServerRepoOwner server)
      (_runningServerRepoName server)
  unless hasAccess $ do
    log Notice "terminal: websocket rejected (no access to the server's repo)"
    throw NotFound
  -- [H2a] Login-user gate, now that the server row is known: only users the
  -- guest actually declares (plus the deploy user), never root.
  requireDeclaredLoginUser server loginUser
  unless (_runningServerStatus server == Online) $ do
    log Notice "terminal: websocket rejected (server not online)"
    throw NotFound
  guestAddr <- case _runningServerIpv4 server of
    Just addr | isPlausibleGuestAddr addr -> pure addr
    _ -> do
      log Notice "terminal: websocket rejected (server has no usable guest address)"
      throw NotFound
  -- Reuse the deploy path's ssh mechanism verbatim: BatchMode, internal-guest
  -- host-key handling, connect timeout, port split. We ssh straight in as the
  -- chosen login user, authenticating with a short-lived per-session
  -- certificate minted per connection (the guest trusts the terminal CA), so
  -- a declared login user like @joe@ is reachable directly without any
  -- standing key for them.
  (guestHost, sshArgs) <- ServerPool.sshArgsFor (GuestAddress guestAddr)
  -- [H3] The dedicated terminal certificate authority (never the
  -- hosting/deploy key): guests trust its public half via TrustedUserCAKeys,
  -- so the deploy/root identity and the terminal-signing identity stay
  -- separable. Absent key file fails closed, before any upgrade.
  caKeyFile <- do
    path <- view #sshTerminalCaKey
    exists <- liftIO $ doesFileExist path
    unless exists $ do
      log Notice "terminal: websocket rejected (terminal CA key not present)"
      throw NotFound
    pure (cs path)
  sourceAddress <- view #sshTerminalSourceAddress
  env <- ask
  pure
    $ terminalApp env (getGhLogin (user ^. githubLogin)) serverId
    $ TerminalTarget
      { ttBaseArgs = sshArgs <> sshHardeningArgs,
        ttGuestHost = guestHost,
        ttLoginUser = loginUser,
        ttCaKeyFile = caKeyFile,
        ttServerIdText = getHashId (getServerId serverId),
        ttSourceAddress = sourceAddress
      }
connectTerminal _ _ _ = do
  log Notice "terminal: unauthenticated websocket rejected"
  throw Unauthorized

-- | The guest login user. Defaults to @garnix@ (the deploy user). A
-- client-supplied override is the single client-influenced token of the ssh
-- argv, so it is gated by a strict allowlist pattern
-- (@^[a-z_][a-z0-9_-]{0,31}$@): it can never start with @-@ (no option
-- injection), never contain whitespace, @\@@, or any shell/ssh
-- metacharacter, and is length-bounded. Anything else is a 400 before any
-- process is spawned. This is only the syntactic gate; once the server row
-- is known, 'requireDeclaredLoginUser' additionally requires the user to be
-- one the guest declared (and never root).
validateLoginUser :: Maybe Text -> M Text
validateLoginUser = \case
  Nothing -> pure defaultLoginUser
  Just requested
    | isValidLoginUser requested -> pure requested
    | otherwise -> do
        log Notice "terminal: websocket rejected (invalid login user)"
        throw $ BadRequest "invalid terminal login user"

defaultLoginUser :: Text
defaultLoginUser = "garnix"

-- | Second gate on the login user, once the server row is known: a session
-- certificate is only minted for login users the guest actually declared at
-- deploy time (servers.ssh_users, captured on the guest via getent — see
-- '_runningServerSshUsers') plus the deploy user @garnix@. @root@ never gets
-- one, even if a guest were to declare it: the web terminal is for
-- interactive logins as declared users, not a root channel.
requireDeclaredLoginUser :: RunningServer -> Text -> M ()
requireDeclaredLoginUser server loginUser
  | loginUser == "root" = do
      log Notice "terminal: websocket rejected (root login refused)"
      throw $ BadRequest "terminal login as root is not allowed"
  | loginUser == defaultLoginUser = pure ()
  | loginUser `elem` fromMaybe [] (_runningServerSshUsers server) = pure ()
  | otherwise = do
      log Notice "terminal: websocket rejected (login user not declared by this server)"
      throw $ BadRequest "login user not declared by this server"

isValidLoginUser :: Text -> Bool
isValidLoginUser user = case T.uncons user of
  Nothing -> False
  Just (first', rest) ->
    T.length user
      <= 32
      && (isAsciiLower first' || first' == '_')
      && T.all (\c -> isAsciiLower c || isDigit c || c == '_' || c == '-') rest

-- | Extra ssh client hardening on top of 'ServerPool.sshArgsFor' (which
-- already sets the hosting identity files, BatchMode, the internal-guest
-- host-key policy and a connect timeout): never forward anything from the
-- backend host into the guest session, and force a TTY for the remote shell.
sshHardeningArgs :: [Text]
sshHardeningArgs =
  [ "-o",
    "ClearAllForwardings=yes",
    "-o",
    "ForwardAgent=no",
    "-o",
    "ForwardX11=no",
    "-o",
    "PermitLocalCommand=no",
    "-o",
    "IdentitiesOnly=yes",
    "-tt"
  ]

-- | The DB-resolved guest address must look like @ip[:port]@. This is a
-- defense-in-depth check (the value is server-side data, and the argv is
-- exec'd without a shell); it also guarantees the destination can never start
-- with @-@ or contain option-like text.
isPlausibleGuestAddr :: Text -> Bool
isPlausibleGuestAddr addr =
  not (T.null addr) && T.all (\c -> isDigit c || c == '.' || c == ':') addr

-- | Newtype adapter so 'ServerPool.sshArgsFor' (written against 'ServerInfo'
-- et al.) accepts a bare DB-resolved guest address.
newtype GuestAddress = GuestAddress Text

instance HasIpv4Addr GuestAddress Text where
  ipv4Addr = lens (\(GuestAddress addr) -> addr) (\_ addr -> GuestAddress addr)

connectionOptions :: WS.ConnectionOptions
connectionOptions =
  WS.defaultConnectionOptions
    { WS.connectionFramePayloadSizeLimit = WS.SizeLimit maxWsPayloadBytes,
      WS.connectionMessageDataSizeLimit = WS.SizeLimit maxWsPayloadBytes
    }

-- | Everything the per-session handler needs to build the ssh command once it
-- has minted the session certificate: the base ssh args (hosting-key @-i@
-- flags + BatchMode/host-key/port options + the terminal hardening flags, with
-- no destination yet), the guest host, the chosen login user, and the terminal
-- CA key file the per-session cert is signed with.
data TerminalTarget = TerminalTarget
  { ttBaseArgs :: [Text],
    ttGuestHost :: Text,
    ttLoginUser :: Text,
    ttCaKeyFile :: Text,
    -- | The server's public hash id (the one in its URLs). Used for the
    -- per-guest cert principal @server-\<id\>@ — so a guest can pin terminal
    -- certs to itself via @AuthorizedPrincipalsFile@ — and for the unique
    -- per-session key id.
    ttServerIdText :: Text,
    -- | When set, baked into the cert as @-O source-address=...@: the cert
    -- then only authenticates from this CIDR (the backend's own address on
    -- the guest bridge; GARNIX_TERMINAL_SOURCE_ADDRESS).
    ttSourceAddress :: Maybe Text
  }

-- | The WAI application run once the caller is authenticated + authorized.
-- Rejects mismatched-Origin browser requests (cross-site WebSocket hijacking
-- of cookie sessions), then performs the upgrade and runs the PTY session
-- under the per-user concurrency cap.
terminalApp :: Env -> Text -> ServerId -> TerminalTarget -> Wai.Application
terminalApp env login serverId target req respond
  | not (originAllowed (env ^. #baseUrl) req) = do
      lifecycle Notice "terminal: websocket rejected (mismatched Origin)"
      respond $ Wai.responseLBS HTTP.status403 [] "Origin not allowed"
  | otherwise = case WaiWs.websocketsApp connectionOptions serverApp req of
      Nothing ->
        respond
          $ Wai.responseLBS
            (HTTP.mkStatus 426 "Upgrade Required")
            [("Upgrade", "websocket")]
            "WebSocket upgrade required"
      Just response -> respond response
  where
    lifecycle :: Severity -> Text -> IO ()
    lifecycle severity msg =
      void
        . runM env
        $ withTextSpans
          [ ("tag", "web-terminal"),
            ("terminal_server_id", getHashId (getServerId serverId)),
            ("terminal_user", login)
          ]
        $ log severity msg

    serverApp :: WS.ServerApp
    serverApp pending =
      withSessionSlot (env ^. #terminalSessions) login rejectOverCap $ do
        conn <- WS.acceptRequest pending
        lifecycle Informational "terminal session opened"
        result <- tryAny (runSession conn target)
        case result of
          Right reason ->
            lifecycle Informational $ "terminal session closed (" <> reason <> ")"
          Left _ -> do
            -- Setup can fail after the upgrade but before 'runSession' reaches
            -- its normal close path (for example, key generation/signing or
            -- PTY spawn). Always send a generic close frame in that case: a
            -- raw TCP close is ambiguous to browsers, was flaky under CI
            -- scheduling, and can strand the UI without a terminal reason.
            -- Keep the underlying exception out of the frame and logs because
            -- it can contain host-side paths or process diagnostics.
            closeGracefully conn "terminal session failed"
            lifecycle Informational "terminal session closed (error)"
      where
        rejectOverCap = do
          lifecycle Notice "terminal: websocket rejected (too many concurrent sessions)"
          WS.rejectRequestWith
            pending
            WS.defaultRejectRequest
              { WS.rejectCode = 429,
                WS.rejectMessage = "Too Many Requests",
                WS.rejectBody = "Too many concurrent terminal sessions"
              }

-- | Run @action@ while holding one of the user's session slots; over the cap,
-- run @onFull@ instead. The slot is released on every exit path.
withSessionSlot :: MVar (Map.Map Text Int) -> Text -> IO () -> IO () -> IO ()
withSessionSlot sessions login onFull action =
  bracket acquire release (\acquired -> if acquired then action else onFull)
  where
    acquire = modifyMVar sessions $ \m ->
      let n = fromMaybe 0 (Map.lookup login m)
       in pure
            $ if n >= maxSessionsPerUser
              then (m, False)
              else (Map.insert login (n + 1) m, True)
    release acquired =
      when acquired
        $ modifyMVar_ sessions
        $ pure
        . Map.update (\n -> if n <= 1 then Nothing else Just (n - 1)) login

-- | Mint the per-session certificate (in a temp dir cleaned up on exit), spawn
-- the ssh argv on a fresh PTY, and pump bytes both ways until the shell exits,
-- the client disconnects, or a timeout fires. Returns a human-readable close
-- reason (never terminal content).
runSession :: WS.Connection -> TerminalTarget -> IO Text
runSession conn target =
  withSystemTempDirectory "garnix-terminal" $ \dir -> do
    sshArgv <- prepareCertSsh dir target
    environ <- getEnvironment
    let childEnv = ("TERM", "xterm-256color") : filter ((/= "TERM") . fst) environ
    bracket (Pty.spawnWithPty (Just childEnv) True "ssh" sshArgv (80, 24)) cleanupPty
      $ \(pty, _processHandle) -> do
        startedAt <- getCurrentTime
        lastActivity <- newIORef startedAt
        outcome <-
          WS.withPingThread conn 30 (pure ())
            $ race
              (race (ptyToWs conn pty lastActivity) (wsToPty conn pty lastActivity))
              (watchdog startedAt lastActivity)
        let reason = case outcome of
              Left (Left ()) -> "shell exited"
              Left (Right ()) -> "connection closed"
              Right timedOut -> timedOut
        closeGracefully conn reason
        pure reason

-- | Mint an ephemeral, per-session SSH user certificate for the target login
-- user in @dir@ and return the ssh argv that authenticates with it. The guest
-- trusts the dedicated terminal CA (@TrustedUserCAKeys@, see
-- @provisioner/guest-profile.nix@), so a short-lived cert signed by it logs us
-- in directly as any declared user without any standing key for them. The
-- throwaway keypair + cert live only in @dir@ (removed when the session ends),
-- the guest is never mutated, and the cert's scope is pinned down by
-- 'signingArgs'.
prepareCertSsh :: FilePath -> TerminalTarget -> IO [String]
prepareCertSsh dir target = do
  let keyPath = dir </> "id"
      certPath = dir </> "id-cert.pub"
  sessionUuid <- Data.UUID.toText <$> Data.UUID.V4.nextRandom
  runKeygen ["-q", "-t", "ed25519", "-N", "", "-C", "garnix-terminal", "-f", keyPath]
  runKeygen (signingArgs target sessionUuid keyPath)
  pure
    $ map cs (ttBaseArgs target)
    <> [ "-i",
         keyPath,
         "-o",
         "CertificateFile=" <> certPath,
         cs (ttLoginUser target) <> "@" <> cs (ttGuestHost target)
       ]

-- | The @ssh-keygen -s@ argv that signs a session certificate (pure, so the
-- spec can pin down exactly what a cert grants):
--
--   * principals: the login user plus @server-\<serverId\>@ — the login-user
--     principal is what sshd matches by default; the per-server principal
--     lets a guest restrict certs to itself via @AuthorizedPrincipalsFile@;
--   * key id: unique per session (server id + session UUID), so guest auth
--     logs attribute each login to exactly one websocket session;
--   * validity: +61m, just over the 60m 'maxSessionDuration' cap (sshd only
--     checks validity once, at authentication);
--   * options: cleared, then @permit-pty@ only — no forwardings — plus
--     @source-address@ pinning the cert to the backend's own guest-bridge
--     address when configured.
signingArgs :: TerminalTarget -> Text -> FilePath -> [String]
signingArgs target sessionUuid keyPath =
  [ "-s",
    cs (ttCaKeyFile target),
    "-I",
    cs ("garnix-web-terminal-" <> ttServerIdText target <> "-" <> sessionUuid),
    "-n",
    cs (ttLoginUser target <> ",server-" <> ttServerIdText target),
    "-V",
    "+61m",
    "-O",
    "clear",
    "-O",
    "permit-pty"
  ]
    <> maybe [] (\addr -> ["-O", cs ("source-address=" <> addr)]) (ttSourceAddress target)
    <> [keyPath <> ".pub"]

-- | Run @ssh-keygen@ with the given args, failing the session (a caught
-- exception that closes the websocket) if it errors. Never logs the args or
-- output — they reference the session key material.
runKeygen :: [String] -> IO ()
runKeygen args = do
  (code, _out, err) <- readProcessWithExitCode "ssh-keygen" args ""
  case code of
    ExitSuccess -> pure ()
    ExitFailure _ -> throwString ("ssh-keygen failed: " <> err)

-- | PTY output -> websocket, as binary frames, until the PTY hits EOF (shell
-- exited) or errors.
ptyToWs :: WS.Connection -> Pty.Pty -> IORef UTCTime -> IO ()
ptyToWs conn pty lastActivity =
  forever
    ( do
        bytes <- Pty.readPty pty
        getCurrentTime >>= writeIORef lastActivity
        WS.sendBinaryData conn bytes
    )
    `catchAny` \_ -> pure ()

-- | Websocket -> PTY: binary frames are raw terminal input; text frames are
-- JSON control messages (currently only resize). Ends when the client closes.
wsToPty :: WS.Connection -> Pty.Pty -> IORef UTCTime -> IO ()
wsToPty conn pty lastActivity =
  forever
    ( do
        message <- WS.receiveDataMessage conn
        getCurrentTime >>= writeIORef lastActivity
        case message of
          WS.Binary bytes -> Pty.writePty pty (cs bytes)
          WS.Text bytes _ -> handleControlMessage pty bytes
    )
    `catchAny` \_ -> pure ()

data ControlMessage = ResizeMessage Int Int

instance FromJSON ControlMessage where
  parseJSON = Aeson.withObject "ControlMessage" $ \o -> do
    messageType :: Text <- o Aeson..: "type"
    case messageType of
      "resize" -> ResizeMessage <$> o Aeson..: "cols" <*> o Aeson..: "rows"
      _ -> fail "unknown control message type"

-- | Apply a control message. Resize dimensions are clamped to sane bounds so
-- the client cannot drive the PTY ioctl with absurd values.
handleControlMessage :: Pty.Pty -> LazyByteString -> IO ()
handleControlMessage pty raw = case Aeson.decode' raw of
  Just (ResizeMessage cols rows) ->
    Pty.resizePty pty (clampTo 2 500 cols, clampTo 2 300 rows)
  Nothing -> pure ()
  where
    clampTo lo hi = max lo . min hi

-- | Ends the session (winning the 'race') when either the absolute duration
-- limit or the idle limit is exceeded.
watchdog :: UTCTime -> IORef UTCTime -> IO Text
watchdog startedAt lastActivity = do
  threadDelay watchdogInterval
  now <- getCurrentTime
  idleSince <- readIORef lastActivity
  if
    | diffTime now startedAt > maxSessionDuration -> pure "session time limit reached"
    | diffTime now idleSince > idleTimeout -> pure "idle timeout"
    | otherwise -> watchdog startedAt lastActivity

-- | Best-effort clean close: send a close frame with the reason, then drain
-- briefly so the peer's close ack is read before the TCP connection drops.
closeGracefully :: WS.Connection -> Text -> IO ()
closeGracefully conn reason =
  void . tryAny $ do
    WS.sendClose conn reason
    void
      $ timeout (toMicroseconds (fromSeconds @Int 2))
      $ forever
      $ void
      $ WS.receiveDataMessage conn

-- | Tear down the ssh child + PTY on every exit path: TERM, close the master
-- (HUPs the child), then reap — escalating to KILL if it ignores both.
cleanupPty :: (Pty.Pty, ProcessHandle) -> IO ()
cleanupPty (pty, processHandle) = do
  void . tryAny $ terminateProcess processHandle
  void . tryAny $ Pty.closePty pty
  void . tryAny $ do
    exited <- timeout (toMicroseconds (fromSeconds @Int 5)) (waitForProcess processHandle)
    when (isNothing exited) $ do
      maybePid <- getPid processHandle
      for_ maybePid (signalProcess sigKILL)
      void $ waitForProcess processHandle

-- | Cross-site WebSocket hijacking defense for cookie-authenticated browser
-- sessions: browsers always send @Origin@ on websocket handshakes, and it
-- must match the app's own origin ('baseUrl'). Requests without an @Origin@
-- header (non-browser clients authenticating via JWT) are allowed — they
-- carry no ambient cookie authority to hijack.
originAllowed :: Text -> Wai.Request -> Bool
originAllowed baseUrl req = case lookup "Origin" (Wai.requestHeaders req) of
  Nothing -> True
  Just origin -> normalizeOrigin (cs origin) == normalizeOrigin baseUrl

normalizeOrigin :: Text -> Text
normalizeOrigin = T.toLower . T.dropWhileEnd (== '/')
