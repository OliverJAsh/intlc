module Intlc.Compiler (compileDataset, compileFlattened, flatten) where

import           Control.Applicative.Combinators   (choice)
import           Data.Aeson                        (encode)
import           Data.ByteString.Lazy              (ByteString)
import           Data.List.Extra                   (firstJust)
import qualified Data.Map                          as M
import qualified Data.Text                         as T
import           Intlc.Backend.ICU.Compiler        (compileMsg)
import           Intlc.Backend.JavaScript.Compiler as JS
import qualified Intlc.Backend.TypeScript.Compiler as TS
import           Intlc.Core
import qualified Intlc.ICU                         as ICU
import           Prelude                           hiding (ByteString)

-- We'll `foldr` with `mempty`, avoiding `mconcat`, to preserve insertion order.
compileDataset :: Locale -> Dataset Translation -> Either (NonEmpty Text) Text
compileDataset l d = validateKeys d $>
  case stmts of
    []     -> JS.emptyModule
    stmts' -> T.intercalate "\n" stmts'
  where stmts = imports <> exports
        imports = maybeToList $ JS.buildReactImport d
        exports = M.foldrWithKey buildCompiledTranslations mempty d
        buildCompiledTranslations k v acc = compileTranslation l k v : acc

validateKeys :: Dataset Translation -> Either (NonEmpty Text) ()
validateKeys = toEither . lefts . fmap (uncurry validate) . M.toList
  where toEither []     = Right ()
        toEither (e:es) = Left $ e :| es
        validate k t = k & case backend t of
          TypeScript      -> TS.validateKey
          TypeScriptReact -> TS.validateKey

compileTranslation :: Locale -> Text -> Translation -> Text
compileTranslation l k (Translation v be _) = case be of
  TypeScript      -> TS.compileNamedExport TemplateLit l k v
  TypeScriptReact -> TS.compileNamedExport JSX         l k v

type ICUBool = (ICU.Stream, ICU.Stream)
type ICUSelect = (NonEmpty ICU.SelectCase, Maybe ICU.SelectWildcard)

compileFlattened :: Dataset Translation -> ByteString
compileFlattened = encode . flattenDataset

flattenDataset :: Dataset Translation -> Dataset UnparsedTranslation
flattenDataset = fmap $ \(Translation msg be md) -> UnparsedTranslation (compileMsg . flatten $ msg) be md

flatten :: ICU.Message -> ICU.Message
flatten x@(ICU.Static _)      = x
flatten (ICU.Dynamic xs)      = ICU.Dynamic . fromList . flattenStream . toList $ xs
  where flattenStream :: ICU.Stream -> ICU.Stream
        flattenStream ys = fromMaybe ys $ choice
          [ mapBool   <$> extractFirstBool ys
          , mapSelect <$> extractFirstSelect ys
          , mapPlural <$> extractFirstPlural ys
          ]
        mapBool (n, ls, boo, rs) = streamFromArg n . uncurry ICU.Bool $ mapBoolStreams (around ls rs) boo
        mapSelect (n, ls, sel, rs) = streamFromArg n . uncurry ICU.Select $ mapSelectStreams (around ls rs) sel
        mapPlural (n, ls, plu, rs) = streamFromArg n .         ICU.Plural $ mapPluralStreams (around ls rs) plu
        around ls rs = flattenStream . ICU.mergePlaintext . surround ls rs
        surround ls rs cs = ls <> cs <> rs
        streamFromArg n = pure . ICU.Interpolation . ICU.Arg n

extractFirstBool :: ICU.Stream -> Maybe (Text, ICU.Stream, ICUBool, ICU.Stream)
extractFirstBool = extractFirstArg $ \case
  ICU.Bool x y -> Just (x, y)
  _            -> Nothing

extractFirstArg :: (ICU.Type -> Maybe a) -> ICU.Stream -> Maybe (Text, ICU.Stream, a, ICU.Stream)
extractFirstArg f xs = firstJust arg (zip [0..] xs)
  where arg (i, ICU.Interpolation (ICU.Arg n t)) = (n, ls, , rs) <$> f t
          where (ls, _:rs) = splitAt i xs
        arg _ = Nothing

extractFirstSelect :: ICU.Stream -> Maybe (Text, ICU.Stream, ICUSelect, ICU.Stream)
extractFirstSelect = extractFirstArg $ \case
  ICU.Select xs y -> Just (xs, y)
  _               -> Nothing

extractFirstPlural :: ICU.Stream -> Maybe (Text, ICU.Stream, ICU.Plural, ICU.Stream)
extractFirstPlural = extractFirstArg $ \case
  ICU.Plural x -> Just x
  _            -> Nothing

mapBoolStreams :: (ICU.Stream -> ICU.Stream) -> ICUBool -> ICUBool
mapBoolStreams f (xs, ys) = (f xs, f ys)

mapSelectStreams :: (ICU.Stream -> ICU.Stream) -> ICUSelect -> ICUSelect
mapSelectStreams f (xs, mw) = (mapSelectCase f <$> xs, mapSelectWildcard f <$> mw)

mapSelectCase :: (ICU.Stream -> ICU.Stream) -> ICU.SelectCase -> ICU.SelectCase
mapSelectCase f (ICU.SelectCase x ys) = ICU.SelectCase x (f ys)

mapSelectWildcard :: (ICU.Stream -> ICU.Stream) -> ICU.SelectWildcard -> ICU.SelectWildcard
mapSelectWildcard f (ICU.SelectWildcard xs) = ICU.SelectWildcard (f xs)

mapPluralStreams :: (ICU.Stream -> ICU.Stream) -> ICU.Plural -> ICU.Plural
mapPluralStreams f (ICU.Cardinal (ICU.LitPlural xs mw))      = ICU.Cardinal $ ICU.LitPlural (mapPluralCase f <$> xs) (mapPluralWildcard f <$> mw)
mapPluralStreams f (ICU.Cardinal (ICU.RulePlural xs w))      = ICU.Cardinal $ ICU.RulePlural (mapPluralCase f <$> xs) (mapPluralWildcard f w)
mapPluralStreams f (ICU.Cardinal (ICU.MixedPlural xs ys w))  = ICU.Cardinal $ ICU.MixedPlural (mapPluralCase f <$> xs) (mapPluralCase f <$> ys) (mapPluralWildcard f w)
mapPluralStreams f (ICU.Ordinal (ICU.OrdinalPlural xs ys w)) = ICU.Ordinal $ ICU.OrdinalPlural (mapPluralCase f <$> xs) (mapPluralCase f <$> ys) (mapPluralWildcard f w)

mapPluralCase :: (ICU.Stream -> ICU.Stream) -> ICU.PluralCase a -> ICU.PluralCase a
mapPluralCase f (ICU.PluralCase x ys) = ICU.PluralCase x (f ys)

mapPluralWildcard :: (ICU.Stream -> ICU.Stream) -> ICU.PluralWildcard -> ICU.PluralWildcard
mapPluralWildcard f (ICU.PluralWildcard xs) = ICU.PluralWildcard (f xs)
