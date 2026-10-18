module CodegenSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.Either (isLeft)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text.IO.Utf8 as TU
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Yuo.Codegen
import Yuo.Llm (LlmBackend (..))
import Yuo.Log (withLogger)

-- | Answers each request with the next file (the last one repeats).
writes :: [Text] -> IO LlmBackend
writes files = do
  queue <- newIORef files
  let next = atomicModifyIORef' queue $ \case
        [f] -> ([f], f)
        f : rest -> (rest, f)
        [] -> ([], "")
  pure (LlmBackend "scripted" (\_ _ _ -> Right . code <$> next))
  where
    code f = object ["code" .= f] :: Value

generate :: FilePath -> LlmBackend -> IO (Either Text FilePath)
generate dir llm = withLogger dir $ \lg ->
  generateSolution (CodegenEnv lg llm dir "songs.txt" "blindly4.exe" (dir </> "solution.py") "schema" (\_ _ -> pure (Right ())))

spec :: Spec
spec = describe "generateSolution" $ do
  it "never overwrites the installed solution.py with a rejected attempt" $
    withSystemTempDirectory "cg" $ \dir -> do
      TU.writeFile (dir </> "solution.py") "previously validated"
      bad <- TU.readFile "test/fixtures/fp_bad_while.py"
      r <- generate dir =<< writes [bad]
      r `shouldSatisfy` isLeft
      TU.readFile (dir </> "solution.py") `shouldReturn` "previously validated"
  it "installs the first attempt that passes the lint and the smoke run, keeping attempts aside" $
    withSystemTempDirectory "cg" $ \dir -> do
      bad <- TU.readFile "test/fixtures/fp_bad_while.py"
      good <- TU.readFile "test/fixtures/fp_good.py"
      r <- generate dir =<< writes [bad, good]
      r `shouldBe` Right (dir </> "solution.py")
      TU.readFile (dir </> "solution.py") `shouldReturn` good
      doesFileExist (dir </> "solution-attempt-0.py") `shouldReturn` True
