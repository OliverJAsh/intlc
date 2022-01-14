module Intlc.ParserSpec (spec) where

import           Intlc.Core
import           Intlc.Parser
import           Prelude               hiding (ByteString)
import           Test.Hspec
import           Test.Hspec.Megaparsec
import           Text.Megaparsec       (ParseErrorBundle, Parsec, parse)
import           Text.Megaparsec.Error (ErrorFancy (ErrorCustom))

parse' :: Parsec e s a -> s -> Either (ParseErrorBundle s e) a
parse' = flip parse "test"

spec :: Spec
spec = describe "parser" $ do
  describe "message" $ do
    it "tolerates unclosed braces" $ do
      parse' msg "a {b} c { d" `shouldParse`
        Dynamic [Plaintext "a ", Interpolation (Arg "b" String), Plaintext " c { d"]

    it "tolerates empty braces" $ do
      parse' msg "a {b} c {} d {e, number}" `shouldParse`
        Dynamic [Plaintext "a ", Interpolation (Arg "b" String), Plaintext " c {} d ", Interpolation (Arg "e" Number)]

  describe "interpolation" $ do
    it "interpolates appropriately" $ do
      parse' interp "{x}" `shouldParse` Arg "x" String

    it "validates closing tag name" $ do
      parse' interp "<hello></hello>" `shouldParse` Arg "hello" (Callback [])
      parse' interp `shouldFailOn` "<hello></there>"

  describe "callback" $ do
    it "reports friendly error for bad closing tag" $ do
      let e i = errFancy i . fancy . ErrorCustom

      parse' callback "<hello> there" `shouldFailWith` e 1 (NoClosingCallbackTag "hello")
      parse' callback "<hello> </there>" `shouldFailWith` e 10 (BadClosingCallbackTag "hello" "there")
