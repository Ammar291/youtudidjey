-- | The song list: one search query per line.
module Yuo.Songs
  ( Song (..)
  , parseSongs
  , readSongs
  ) where

import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)

data Song = Song {songIndex :: Int, songQuery :: Text}
  deriving (Eq, Show)

-- | Drops a BOM, blank lines and @#@ comments; trims each query.
parseSongs :: Text -> [Song]
parseSongs = zipWith Song [0 ..] . filter keep . map T.strip . T.lines . T.dropWhile (== '\xFEFF')
  where
    keep l = not (T.null l) && not ("#" `T.isPrefixOf` l)

-- | Always UTF-8, whatever the console code page is.
readSongs :: FilePath -> IO [Song]
readSongs file = parseSongs . TE.decodeUtf8With lenientDecode <$> BS.readFile file
