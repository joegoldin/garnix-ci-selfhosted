{-# OPTIONS_GHC -fno-warn-orphans #-}

module Garnix.Prelude
  ( module M,
    identity,
    curry3,
    curry4,
    curry5,
    curry6,
    curry7,
    location,
    putText,
    putTextLn,
    show,
    showPretty,
    pShow,
    pPrint,
    dbg,
    dbgM,
    dbgM_,
    error,
    slidingWindow',
    try,
    whenError,
    withError,
    whenIs,
    whenM,
    unlessM,
    ourToJSON,
    ourToEncoding,
    ourParseJSON,
    HashId,
    hashIdText,
    hashIdInt,
    getHashId,
    isValidSubdomainString,
    xdgCacheHome,
    randomElement,
    randomBase64,
    uniq,
  )
where

import Control.Applicative as M
import Control.Concurrent.Async.Lifted as M (forConcurrently, forConcurrently_)
import Control.Concurrent.Lifted as M (ThreadId, fork, killThread)
import Control.Exception.Safe as M (catch, catchAny)
import Control.Lens (_head)
import Control.Lens as M
  ( Iso,
    Iso',
    Lens,
    Lens',
    Prism,
    Prism',
    at,
    coerced,
    contramap,
    each,
    filtered,
    from,
    iso,
    lens,
    makeFields,
    makePrisms,
    mapped,
    prism,
    re,
    review,
    to,
    view,
    views,
    (%~),
    (&),
    (.~),
    (?~),
    (^.),
    (^..),
    (^?),
    _1,
    _2,
    _3,
    _Just,
    _Left,
    _Right,
  )
import Control.Monad as M (filterM, foldM, forever, guard, join, replicateM, replicateM_, unless, when, (<=<), (>=>))
import Control.Monad.Catch as M hiding (catch, try)
import Control.Monad.Except as M hiding (withError)
import Control.Monad.Reader as M
import Control.Monad.State as M
import Control.Monad.Trans.Control as M (MonadBaseControl, liftBaseOp)
import Control.Monad.Trans.Resource as M (ResourceT, runResourceT)
import Data.Aeson as M (FromJSON (..), FromJSONKey (..), ToJSON (..), ToJSONKey (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.QQ as M (aesonQQ)
import Data.Aeson.Types qualified as Aeson
import Data.Bifunctor as M (Bifunctor, bimap, first, second)
import Data.Char (toLower)
import Data.Coerce as M (coerce)
import Data.Default.Class as M
import Data.Either as M (isLeft, isRight)
import Data.Foldable as M
import Data.Function as M (on)
import Data.Functor as M (void, ($>))
import Data.Generics.Labels ()
import Data.Int as M (Int16, Int32, Int64)
import Data.List as M hiding (delete)
import Data.List.NonEmpty as M (NonEmpty ((:|)))
import Data.Maybe as M (catMaybes, fromMaybe, isJust, isNothing)
import Data.Proxy as M (Proxy (Proxy))
import Data.Row.Aeson ()
import Data.Sequence as M (Seq)
import Data.Set as M (Set)
import Data.String.Conversions as M (ConvertibleStrings (convertString), LazyByteString, LazyText, StrictByteString, StrictText, cs)
import Data.Text as M (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Time.Clock as M (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime, getCurrentTime, nominalDiffTimeToSeconds, secondsToNominalDiffTime)
import Data.Traversable as M (forM)
import Data.Tuple as M (swap)
import Data.Typeable as M (Typeable)
import Data.Vector as M (Vector)
import Database.PostgreSQL.Typed as M (PGConnection)
import Database.PostgreSQL.Typed.HDBC as M (Connection, withPGConnection)
import Database.PostgreSQL.Typed.Types as M (PGColumn (..), PGParameter (..), PGType (..), PGTypeID (..))
import Debug.Trace (trace)
import GHC.Exts as M (Constraint, IsString (..))
import GHC.Generics as M (Generic, Rep)
import GHC.OverloadedLabels as M (IsLabel (..))
import GHC.Stack as M (CallStack, HasCallStack, SrcLoc, callStack, getCallStack, prettyCallStack)
import GHC.TypeLits as M (Symbol)
import Generics.Eot (HasEot, datatype, datatypeName)
import Iso.Deriving as M (As (..), As1 (..), Inject (..), Isomorphic, Project (..))
import Network.Wai (Application)
import Prettyprinter as M (Pretty (..), pretty, vsep, (<+>))
import Prettyprinter as Pretty
import Prettyprinter.Render.Text as Pretty
import Servant as M
  ( Capture,
    Delete,
    FromHttpApiData (..),
    Get,
    Header,
    Headers,
    JSON,
    NoContent (..),
    Patch,
    Post,
    QueryParam,
    ReqBody,
    ToHttpApiData (..),
    addHeader,
    (:>),
  )
import Servant qualified
import Servant.API.Generic as M ((:-))
import Servant.Auth.Server as M (FromJWT, ToJWT)
import Servant.Auth.Server.Internal.AddSetCookie (AddSetCookieApi, AddSetCookies (..), Nat (S))
import Servant.RawM (RawM')
import Servant.Server.Generic as M (AsServerT)
import Streaming as M (Of, Stream)
import Streaming.ByteString.Char8 as M (ByteStream)
import Streaming.Prelude qualified as S
import System.Environment as M (lookupEnv)
import System.FilePath.Posix as M (takeDirectory, (</>))
import System.IO as M (BufferMode (..), Handle, hSetBuffering, stderr, stdout)
import System.Random (randomRIO)
import Text.Show.Pretty qualified
import Web.Hashids qualified as Hashids
import "base64-bytestring" Data.ByteString.Base64 qualified as Base64
import "crypton" Crypto.Random.Entropy qualified as Random
import Prelude as M hiding (error, id, log, show)
import Prelude qualified

identity :: a -> a
identity x = x

curry3 :: ((a, b, c) -> output) -> a -> b -> c -> output
curry3 fun a b c = fun (a, b, c)

curry4 :: ((a, b, c, d) -> output) -> a -> b -> c -> d -> output
curry4 fun a b c d = fun (a, b, c, d)

curry5 :: ((a, b, c, d, e) -> output) -> a -> b -> c -> d -> e -> output
curry5 fun a b c d e = fun (a, b, c, d, e)

curry6 :: ((a, b, c, d, e, f) -> output) -> a -> b -> c -> d -> e -> f -> output
curry6 fun a b c d e f = fun (a, b, c, d, e, f)

curry7 :: ((a, b, c, d, e, f, g) -> output) -> a -> b -> c -> d -> e -> f -> g -> output
curry7 fun a b c d e f g = fun (a, b, c, d, e, f, g)

location :: (HasCallStack) => SrcLoc
location =
  case getCallStack callStack of
    (_, srcLoc) : _ -> srcLoc
    _ -> error "impossible"

putText :: (MonadIO m) => Text -> m ()
putText = liftIO . T.putStr

putTextLn :: (MonadIO m) => Text -> m ()
putTextLn = liftIO . T.putStrLn

show :: (Show a) => a -> Text
show = cs . Prelude.show

showPretty :: (Pretty a) => a -> Text
showPretty = Pretty.renderStrict . Pretty.layoutPretty Pretty.defaultLayoutOptions . pretty

pShow :: (Show a) => a -> Text
pShow = cs . Text.Show.Pretty.ppShow

pPrint :: (Show a, MonadIO m) => a -> m ()
pPrint = liftIO . Text.Show.Pretty.pPrint

dbg :: (Show a) => a -> a
dbg a = trace ("dbg: " <> Text.Show.Pretty.ppShow a) a

dbgM :: (MonadIO m, Show a) => a -> m a
dbgM a = dbgM_ a $> a

dbgM_ :: (MonadIO m, Show a) => a -> m ()
dbgM_ a = liftIO $ T.hPutStrLn stderr ("dbgM: " <> cs (Text.Show.Pretty.ppShow a))

error :: (HasCallStack) => Text -> a
error = Prelude.error . cs

try :: (MonadError e m) => m a -> m (Either e a)
try a = (Right <$> a) `catchError` (pure . Left)

whenError :: (MonadError e m) => m a -> (e -> m ()) -> m a
whenError action note = action `catchError` (\e -> note e >> throwError e)

withError :: (MonadError e m) => (e -> e) -> m a -> m a
withError f action = try action >>= either (throwError . f) pure

-- | Similar to `when`, but takes a value, and a prism into the value, instead.
whenIs :: (Applicative m) => Prism' a b -> a -> (b -> m ()) -> m ()
whenIs prism_ val act = case val ^? prism_ of
  Nothing -> pure ()
  Just v -> act v

-- | Monadic version of @when@
whenM :: (Monad m) => m Bool -> m () -> m ()
whenM mb thing = mb >>= \b -> when b thing

-- | Monadic version of @unless@
unlessM :: (Monad m) => m Bool -> m () -> m ()
unlessM condM acc = condM >>= \cond -> unless cond acc

-- * HashIds

hashIdContext :: Hashids.HashidsContext
hashIdContext = Hashids.hashidsMinimum "the smell of petroleum pervades throughout" 8

-- | A hashid is an opaque ID generated from an int.
--
-- This should only be constructed from the DB, so we don't export the
-- constructor.
newtype HashId = HashId {getHashId :: Text}
  deriving stock (Eq, Show)
  deriving newtype (ToJSON, FromJSON, Pretty, ToHttpApiData)

instance Servant.FromHttpApiData HashId where
  parseUrlPiece piece = case Hashids.decode hashIdContext (cs piece) of
    [_] -> Right $ HashId piece
    _ -> Left $ "Invalid hash id: " <> piece

instance PGParameter "bigint" HashId where
  pgEncode t (HashId bs) = case Hashids.decode hashIdContext (cs bs) of
    [i] -> pgEncode t (fromIntegral i :: Int64)
    err -> error $ "expected single integer: " <> show err

instance PGColumn "bigint" HashId where
  pgDecode t i =
    HashId $ cs $ Hashids.encode hashIdContext (fromIntegral (pgDecode t i :: Int64))

hashIdText :: Prism' Text HashId
hashIdText = prism there back
  where
    there = getHashId
    back t = case Hashids.decode hashIdContext (cs t) of
      [_] -> pure $ HashId t
      _ -> Left "Expected a single integer"

hashIdInt :: Iso' HashId Int
hashIdInt = iso hashIdToInt intToHashId
  where
    intToHashId int = HashId $ cs $ Hashids.encode hashIdContext int
    hashIdToInt hashId = case Hashids.decode hashIdContext $ cs $ getHashId hashId of
      [int] -> int
      _ -> error "HashId should always decode into single element integers"

-- * Aeson helpers

ourOpts :: forall a. (HasEot a) => Proxy a -> Aeson.Options
ourOpts p =
  Aeson.defaultOptions
    { Aeson.fieldLabelModifier = \field ->
        let prefix = ("_" <> (datatypeName (datatype p) & _head %~ toLower))
         in case stripPrefix prefix field of
              Just stripped -> Aeson.camelTo2 '_' stripped
              Nothing -> error $ "ourOpts: cannot strip " <> cs prefix <> " from " <> cs field,
      Aeson.omitNothingFields = True
    }

ourToEncoding ::
  forall a.
  (Generic a, Aeson.GToJSON' Aeson.Encoding Aeson.Zero (Rep a), HasEot a) =>
  a ->
  Aeson.Encoding
ourToEncoding = Aeson.genericToEncoding (ourOpts p)
  where
    p :: Proxy a
    p = Proxy

ourToJSON ::
  forall a.
  (Generic a, Aeson.GToJSON' Aeson.Value Aeson.Zero (Rep a), HasEot a) =>
  a ->
  Aeson.Value
ourToJSON = Aeson.genericToJSON (ourOpts p)
  where
    p :: Proxy a
    p = Proxy

ourParseJSON ::
  forall a.
  (Generic a, Aeson.GFromJSON Aeson.Zero (Rep a), HasEot a) =>
  Aeson.Value ->
  Aeson.Parser a
ourParseJSON = Aeson.genericParseJSON (ourOpts p)
  where
    p :: Proxy a
    p = Proxy

-- * Streaming

-- | A sliding window like streaming's slidingWindow, but doesn't wait to min
-- value to start yielding.
slidingWindow' ::
  forall a b m.
  (Monad m) =>
  Int ->
  Stream (Of [a]) m b ->
  Stream (Of [a]) m b
slidingWindow' n = window mempty
  where
    lastN :: [a] -> (Int, [a])
    lastN a =
      let l = length a
       in if l > n then (n, drop (l - n) a) else (l, a)

    window :: (Monad m) => [a] -> Stream (Of [a]) m b -> Stream (Of [a]) m b
    window !sequ str = do
      e <- lift (S.next str)
      case e of
        Left r -> return r
        Right (a, rest) -> do
          let (_, a') = lastN (sequ <> a)
          S.yield a'
          window a' rest

instance (Isomorphic a b, IsString a) => IsString (As a b) where
  fromString x = As $ inj (fromString x :: a)

instance (Isomorphic a b, Aeson.FromJSON a) => Aeson.FromJSON (As a b) where
  parseJSON x = fmap (As . inj) (Aeson.parseJSON x :: Aeson.Parser a)

instance (Isomorphic a b, Aeson.ToJSON a) => Aeson.ToJSON (As a b) where
  toJSON (As x) = Aeson.toJSON (prj x :: a)

instance (Isomorphic a b, FromHttpApiData a) => FromHttpApiData (As a b) where
  parseUrlPiece x = fmap (As . inj) (parseUrlPiece x :: Either Text a)

instance (Isomorphic a b, ToHttpApiData a) => ToHttpApiData (As a b) where
  toUrlPiece (As x) = toUrlPiece (prj x :: a)

instance (Isomorphic a b, Aeson.ToJSONKey a) => Aeson.ToJSONKey (As a b) where
  toJSONKey = contramap (\(As b) -> prj b) (Aeson.toJSONKey :: Aeson.ToJSONKeyFunction a)
  toJSONKeyList = contramap (fmap (\(As b) -> prj b)) (Aeson.toJSONKeyList :: Aeson.ToJSONKeyFunction [a])

instance (Isomorphic a b, Aeson.FromJSONKey a) => Aeson.FromJSONKey (As a b) where
  fromJSONKey = fmap (As . inj) (Aeson.fromJSONKey :: Aeson.FromJSONKeyFunction a)
  fromJSONKeyList = fmap (fmap (As . inj)) (Aeson.fromJSONKeyList :: Aeson.FromJSONKeyFunction [a])

instance (Isomorphic a b, PGParameter t a) => PGParameter t (As a b) where
  pgEncode i (As b) = pgEncode i (prj b :: a)

instance (Isomorphic a b, PGColumn t a) => PGColumn t (As a b) where
  pgDecode i x = As $ inj (pgDecode i x :: a)

-- Type instance for RawM for SetCookie API
type instance AddSetCookieApi (RawM' a) = RawM' a

-- Provide an @AddSetCookies@ instance for functors of Application.
instance
  (Functor m) =>
  AddSetCookies ('S n) (m Application) (m Application)
  where
  addSetCookies cookies = fmap $ addSetCookies cookies

isValidSubdomainString :: Text -> Bool
isValidSubdomainString x =
  T.all (`elem` allowed) x
    && not ("-" `T.isPrefixOf` x)
    && not ("-" `T.isSuffixOf` x)
  where
    allowed = ['A' .. 'Z'] ++ ['0' .. '9'] ++ ['a' .. 'z'] ++ ['-']

xdgCacheHome :: String
xdgCacheHome = "XDG_CACHE_HOME"

randomElement :: (MonadIO m) => [a] -> m a
randomElement list = do
  index <- randomRIO (0, length list - 1)
  pure $ list !! index

randomBase64 :: (MonadIO m) => Int -> m Text
randomBase64 size = cs . Base64.encode <$> liftIO (Random.getEntropy size)

uniq :: (Eq a) => [a] -> [a]
uniq = \case
  [] -> []
  [a] -> [a]
  a : b : rest ->
    if a == b
      then uniq (b : rest)
      else a : uniq (b : rest)
