-- | Small concurrency combinators.
module Yuo.Concurrent
  ( firstJust
  ) where

import Control.Concurrent.Async (async, cancel, waitAnyCatch)
import Control.Exception (finally)

-- | Runs every attempt at once and returns the first 'Just' to finish, cancelling the rest.
-- An attempt that throws counts as 'Nothing'.
firstJust :: [IO (Maybe a)] -> IO (Maybe a)
firstJust attempts = do
  running <- mapM async attempts
  let go [] = pure Nothing
      go pending = do
        (done, result) <- waitAnyCatch pending
        case result of
          Right (Just x) -> pure (Just x)
          _ -> go (filter (/= done) pending)
  go running `finally` mapM_ cancel running
