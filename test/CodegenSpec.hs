module CodegenSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.Either (isLeft)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
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
generate dir llm = generateWith dir llm (\_ _ -> pure (Right ()))

generateWith :: FilePath -> LlmBackend -> (Int -> FilePath -> IO (Either SmokeFailure ())) -> IO (Either Text FilePath)
generateWith dir llm smoke = withLogger dir $ \lg ->
  generateSolution (CodegenEnv lg llm dir "songs.txt" "blindly4.exe" (dir </> "solution.py") "schema" smoke)

-- | Smoke results in order (the last one repeats), counting the runs.
smokes :: [Either SmokeFailure ()] -> IO (IORef Int, Int -> FilePath -> IO (Either SmokeFailure ()))
smokes results = do
  queue <- newIORef results
  runs <- newIORef 0
  let next _ _ = do
        modifyIORef' runs (+ 1)
        atomicModifyIORef' queue $ \case
          [r] -> ([r], r)
          r : rest -> (rest, r)
          [] -> ([], Right ())
  pure (runs, next)

-- | Wraps an LLM backend, counting its requests.
counted :: LlmBackend -> IO (IORef Int, LlmBackend)
counted (LlmBackend name ask) = do
  n <- newIORef 0
  pure (n, LlmBackend name (\a b c -> modifyIORef' n (+ 1) >> ask a b c))

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
  it "re-runs the smoke test when the browser was not ready, without asking for a repair" $
    withSystemTempDirectory "cg" $ \dir -> do
      good <- TU.readFile "test/fixtures/fp_good.py"
      (asks, llm) <- counted =<< writes [good]
      (runs, smoke) <- smokes [Left (EnvironmentFailed "player never appeared"), Right ()]
      generateWith dir llm smoke `shouldReturn` Right (dir </> "solution.py")
      readIORef asks `shouldReturn` 1
      readIORef runs `shouldReturn` 2
  it "gives up without blaming the candidate when the browser stays unready" $
    withSystemTempDirectory "cg" $ \dir -> do
      good <- TU.readFile "test/fixtures/fp_good.py"
      (asks, llm) <- counted =<< writes [good]
      (_, smoke) <- smokes [Left (EnvironmentFailed "player never appeared")]
      r <- generateWith dir llm smoke
      r `shouldSatisfy` either ("environment" `T.isInfixOf`) (const False)
      readIORef asks `shouldReturn` 1
  it "sends a candidate's own smoke failure back for repair" $
    withSystemTempDirectory "cg" $ \dir -> do
      good <- TU.readFile "test/fixtures/fp_good.py"
      (asks, llm) <- counted =<< writes [good]
      (_, smoke) <- smokes [Left (CandidateFailed "no playback_started event"), Right ()]
      generateWith dir llm smoke `shouldReturn` Right (dir </> "solution.py")
      readIORef asks `shouldReturn` 2
