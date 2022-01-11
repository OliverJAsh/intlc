module Intlc.EndToEndSpec (spec) where

import           Data.ByteString.Lazy (ByteString)
import           Intlc.Compiler       (dataset)
import           Intlc.Parser         (parseDataset)
import           Prelude              hiding (ByteString)
import           Test.Hspec

(=*=) :: ByteString -> Text -> IO ()
x =*= y = f x `shouldBe` Right y
  where f = fmap dataset . parseDataset

spec :: Spec
spec = describe "end-to-end" $ do
  it "example message" $ do
        "{ \"title\": \"Unsplash\", \"greeting\": \"Hello {name}, {age, number}!\" }"
    =*= "export default {\n  greeting: (x: { name: string; age: number }) => `Hello ${x.name}, ${x.age}!`,\n  title: 'Unsplash',\n}"
