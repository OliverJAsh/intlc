-- This module follows the following whitespace rules:
--   * Consume all whitespace after tokens where possible.
--   * Therefore, assume no whitespace before tokens.

{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use newtype instead of data" #-}

module Intlc.Parser where

import qualified Control.Applicative.Combinators.NonEmpty as NE
import           Data.Aeson                               (decode)
import           Data.ByteString.Lazy                     (ByteString)
import qualified Data.Map                                 as M
import qualified Data.Text                                as T
import           Data.Validation                          (toEither,
                                                           validationNel)
import           Data.Void                                ()
import           Intlc.Core
import           Intlc.ICU
import           Prelude                                  hiding (ByteString)
import           Text.Megaparsec                          hiding (State, Stream,
                                                           Token, many, some,
                                                           token)
import           Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer               as L
import           Text.Megaparsec.Error.Builder

type ParseErr = ParseErrorBundle Text MessageParseErr

data ParseFailure
  = FailedJsonParse
  | FailedDatasetParse (NonEmpty ParseErr)
  deriving (Show, Eq)

data MessageParseErr
  = NoClosingCallbackTag Text
  | BadClosingCallbackTag Text Text
  deriving (Show, Eq, Ord)

instance ShowErrorComponent MessageParseErr where
  showErrorComponent (NoClosingCallbackTag x)    = "Callback tag <" <> T.unpack x <> "> not closed"
  showErrorComponent (BadClosingCallbackTag x y) = "Callback tag <" <> T.unpack x <> "> not closed, instead found </" <> T.unpack y <> ">"

failingWith :: MonadParsec e s m => Int -> e -> m a
pos `failingWith` e = parseError . errFancy pos . fancy . ErrorCustom $ e

printErr :: ParseFailure -> String
printErr FailedJsonParse         = "Failed to parse JSON"
printErr (FailedDatasetParse es) = intercalate "\n" . toList . fmap errorBundlePretty $ es

parseDataset :: ByteString -> Either ParseFailure (Dataset Translation)
parseDataset = parse' <=< decode'
  where decode' = maybeToRight FailedJsonParse . decode
        parse' = toEither . first FailedDatasetParse . M.traverseWithKey ((validationNel .) . parseTranslationFor)

parseTranslationFor :: Text -> UnparsedTranslation -> Either ParseErr Translation
parseTranslationFor name (UnparsedTranslation umsg be md) = do
  msg' <- runParser (runReaderT msg initialState) (T.unpack name) umsg
  pure $ Translation msg' be md

data ParserState = ParserState
  { pluralCtxName :: Maybe Text
  }

initialState :: ParserState
initialState = ParserState mempty

type Parser = ReaderT ParserState (Parsec MessageParseErr Text)

ident :: Parser Text
ident = T.pack <$> some letterChar

msg :: Parser Message
msg = f . mergePlaintext <$> manyTill token eof
  where f []            = Static ""
        f [Plaintext x] = Static x
        f (x:xs)        = Dynamic (x :| xs)

token :: Parser Token
token = choice
  [ Interpolation <$> (interp <|> callback)
  -- Plural cases support interpolating the number/argument in context with
  -- `#`. When there's no such context, fail the parse in effect treating it
  -- as plaintext.
  , asks pluralCtxName >>= \case
      Just n  -> Interpolation (Arg n PluralRef) <$ string "#"
      Nothing -> empty
  , Plaintext <$> (try escaped <|> plaintext)
  ]

plaintext :: Parser Text
plaintext = T.singleton <$> L.charLiteral

escaped :: Parser Text
escaped = apos *> choice
  -- Double escape two apostrophes as one: "''" -> "'"
  [ "'" <$ apos
  -- Escape everything until another apostrophe, being careful of internal
  -- double escapes: "'{a''}'" -> "{a'}"
  , try $ T.pack <$> someTillNotDouble L.charLiteral apos
  -- Escape the next syntax character as plaintext: "'{" -> "{"
  , T.singleton <$> syn
  ]
  where apos = char '\''
        syn = char '{' <|> char '<'
        -- Like `someTill`, but doesn't end upon encountering two `end` tokens,
        -- instead consuming them as one and continuing.
        someTillNotDouble p end = tryOne
          where tryOne = (:) <$> p <*> go
                go = ((:) <$> try (end <* end) <*> go) <|> (mempty <$ end) <|> tryOne

callback :: Parser Arg
callback = do
  oname <- string "<" *> ident <* string ">"
  mrest <- observing ((,,) <$> children <* string "</" <*> getOffset <*> ident <* string ">")
  case mrest of
    Left _  -> 1 `failingWith` NoClosingCallbackTag oname
    Right (ch, pos, cname) -> if oname == cname
       then pure (Arg oname ch)
       else pos `failingWith` BadClosingCallbackTag oname cname
    where children = Callback . mergePlaintext <$> manyTill token (lookAhead $ string "</")

interp :: Parser Arg
interp = do
  n <- string "{" *> ident
  Arg n <$> choice
    [ String <$ string "}"
    , sep *> body n <* string "}"
    ]
  where sep = string "," <* hspace1
        body n = choice
          [ uncurry Bool <$> (string "boolean" *> sep *> boolCases)
          , Number <$ string "number"
          , Date <$> (string "date" *> sep *> dateTimeFmt)
          , Time <$> (string "time" *> sep *> dateTimeFmt)
          , Plural <$> withPluralCtx n (
                  string "plural" *> sep *> cardinalPluralCases
              <|> string "selectordinal" *> sep *> ordinalPluralCases
            )
          , uncurry Select <$> (string "select" *> sep *> selectCases)
          ]
        withPluralCtx n = withReaderT (const . ParserState . pure $ n)

dateTimeFmt :: Parser DateTimeFmt
dateTimeFmt = choice
  [ Short  <$ string "short"
  , Medium <$ string "medium"
  , Long   <$ string "long"
  , Full   <$ string "full"
  ]

caseBody :: Parser Stream
caseBody = mergePlaintext <$> (string "{" *> manyTill token (string "}"))

boolCases :: Parser (Stream, Stream)
boolCases = (,)
  <$> (string "true"  *> hspace1 *> caseBody)
   <* hspace1
  <*> (string "false" *> hspace1 *> caseBody)

selectCases :: Parser (NonEmpty SelectCase, Maybe SelectWildcard)
selectCases = (,) <$> cases <*> optional wildcard
  where cases = NE.sepEndBy1 (SelectCase <$> (name <* hspace1) <*> caseBody) hspace1
        wildcard = SelectWildcard <$> (string wildcardName *> hspace1 *> caseBody)
        name = try $ mfilter (/= wildcardName) ident
        wildcardName = "other"

cardinalPluralCases :: Parser Plural
cardinalPluralCases = fmap Cardinal . tryClassify =<< p
    where tryClassify = maybe empty pure . uncurry classifyCardinal
          p = (,) <$> disorderedPluralCases <*> optional pluralWildcard

ordinalPluralCases :: Parser Plural
ordinalPluralCases = fmap Ordinal . tryClassify =<< p
    where tryClassify = maybe empty pure . uncurry classifyOrdinal
          p = (,) <$> disorderedPluralCases <*> pluralWildcard

-- Need to lift parsed plural cases into this type to make the list homogeneous.
data ParsedPluralCase
  = ParsedExact (PluralCase PluralExact)
  | ParsedRule (PluralCase PluralRule)

disorderedPluralCases :: Parser (NonEmpty ParsedPluralCase)
disorderedPluralCases = flip NE.sepEndBy1 hspace1 $ choice
  [ (ParsedExact .) . PluralCase <$> pluralExact <* hspace1 <*> caseBody
  , (ParsedRule .)  . PluralCase <$> pluralRule  <* hspace1 <*> caseBody
  ]

pluralExact :: Parser PluralExact
pluralExact = PluralExact . T.pack <$> (string "=" *> some numberChar)

pluralRule :: Parser PluralRule
pluralRule = choice
  [ Zero <$ string "zero"
  , One  <$ string "one"
  , Two  <$ string "two"
  , Few  <$ string "few"
  , Many <$ string "many"
  ]

pluralWildcard :: Parser PluralWildcard
pluralWildcard = PluralWildcard <$> (string "other" *> hspace1 *> caseBody)

-- | To simplify parsing cases we validate after-the-fact here. This achieves
-- two purposes. Firstly it enables us to fail the parse if the cases are not
-- exclusively literals and there's no wildcard (see below), and secondly it
-- allows us to organise the cases into the appropriate `Plural` constructors,
-- which in turn enables more efficient codegen later on.
--
--  =0 {}  =1 {}            -- Lit
--  =0 {}  =1 {} other {}   -- Lit
-- one {} two {} other {}   -- Rule
--  =0 {} one {} other {}   -- Mixed
--
classifyCardinal :: Foldable f => f ParsedPluralCase -> Maybe PluralWildcard -> Maybe CardinalPlural
classifyCardinal xs mw =
  case (organisePluralCases xs, mw) of
    ((Just ls, Nothing), mw')     -> Just (LitPlural   ls mw')
    ((Nothing, Just rs), Just w)  -> Just (RulePlural  rs w)
    ((Just ls, Just rs), Just w)  -> Just (MixedPlural ls rs w)
    -- Rule plurals require a wildcard.
    ((_,       Just _),  Nothing) -> Nothing
    -- We should have parsed and organised at least one case somewhere.
    ((Nothing, Nothing), _)       -> Nothing

-- | This is simpler than its cardinal counterpart. Here we need only validate
-- that there is at least one rule case. This is performed here to simplify
-- supporting disordered cases in the parser (whereas validating the presence
-- of a wildcard at the end is trivial in the parser).
classifyOrdinal :: Foldable f => f ParsedPluralCase -> PluralWildcard -> Maybe OrdinalPlural
classifyOrdinal xs w =
  case organisePluralCases xs of
    (_, Nothing)   -> Nothing
    (mls, Just rs) -> Just $ OrdinalPlural (foldMap toList mls) rs w

organisePluralCases :: Foldable f => f ParsedPluralCase -> (Maybe (NonEmpty (PluralCase PluralExact)), Maybe (NonEmpty (PluralCase PluralRule)))
organisePluralCases = bimap nonEmpty nonEmpty . foldr f mempty
  where f (ParsedExact x) = first (x:)
        f (ParsedRule x)  = second (x:)
