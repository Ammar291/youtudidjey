module SongsSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Yuo.Songs

spec :: Spec
spec = describe "parseSongs" $ do
  it "strips a BOM, blank lines, comments, CRLF and surrounding spaces" $
    parseSongs "\xFEFF\&Daft Punk Get Lucky\n\n# comment\n  Beyonc\233 Halo  \r\n"
      `shouldBe` [Song 0 "Daft Punk Get Lucky", Song 1 "Beyonc\233 Halo"]
  it "returns no songs for an empty file" $
    parseSongs "" `shouldBe` []
  it "reads songs.txt as UTF-8 regardless of the console code page" $
    withSystemTempDirectory "songs" $ \dir -> do
      let file = dir </> "songs.txt"
      BS.writeFile file (TE.encodeUtf8 (T.pack "Beyonc\233 Halo\n\1593\1605\1585\1608 \1583\1610\1575\1576\n"))
      readSongs file `shouldReturn` [Song 0 "Beyonc\233 Halo", Song 1 (T.pack "\1593\1605\1585\1608 \1583\1610\1575\1576")]
