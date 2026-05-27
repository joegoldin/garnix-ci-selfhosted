import Data.Text.IO qualified as T
import Garnix.Prelude
import System.Environment (getArgs)
import Text.Read (readMaybe)

main :: IO ()
main = do
  args <- fmap cs <$> getArgs
  forM_ args $ \arg -> do
    case cs arg ^? hashIdText of
      Just hashId -> output hashId
      Nothing -> case readMaybe arg of
        Just int -> output (int ^. re hashIdInt)
        Nothing -> error $ "cannot parse " <> cs arg

output :: HashId -> IO ()
output hashId =
  T.putStrLn $ (hashId ^. re hashIdText) <> " - " <> show (hashId ^. hashIdInt)
