module Intlc.Backend.TypeScript.Language where

import           Data.List          (findIndex)
import           Data.List.NonEmpty (nub)
import qualified Intlc.ICU          as ICU
import           Optics             (ix)
import           Optics.Operators
import           Prelude

-- | A representation of the type-level output we will be compiling. It's a
-- little verbose split into these various sum types, but in doing so it's
-- correct by construction.
data TypeOf = Lambda Args Out
  deriving (Show, Eq)

-- Avoid `Map` due to its `Ord` constraint.
type Args = [(Text, NonEmpty In)]

data Uni
  = TStr
  deriving (Show, Eq)

data In
  = TUniIn Uni
  | TStrLitUnion (NonEmpty Text)
  | TNumLitUnion (NonEmpty Text)
  | TNum
  | TDate
  -- An endomorphism on `Out`. Omitted as an argument to enforce that it's the
  -- same type as the output of the top-level `Lambda`.
  | TEndo
  deriving (Show, Eq)

data Out
  = TUniOut Uni
  | TFragment
  deriving (Show, Eq)

isUnion :: In -> Bool
isUnion TStrLitUnion {} = True
isUnion TNumLitUnion {} = True
isUnion _               = False

-- Collate arguments with the same name.
collateArgs :: Args -> Args
collateArgs = reverse . fmap (second nub) . go [] where
  go acc []            = acc
  go acc (x@(n,ys):xs) =
    case findIndex ((== n) . fst) acc of
      Nothing -> go (x:acc) xs
      Just i  -> go (acc & ix i %~ second (<> ys)) xs

fromMsg :: Out -> ICU.Message -> TypeOf
fromMsg x ICU.Static {}    = Lambda mempty x
fromMsg x (ICU.Dynamic ys) = Lambda (collateArgs (fromToken =<< toList ys)) x

fromToken :: ICU.Token -> Args
fromToken ICU.Plaintext {}      = mempty
fromToken (ICU.Interpolation x) = fromArg x

fromArg :: ICU.Arg -> Args
fromArg (ICU.Arg n ICU.String)         = pure (n, pure $ TUniIn TStr)
fromArg (ICU.Arg n ICU.Number)         = pure (n, pure TNum)
fromArg (ICU.Arg n ICU.Date {})        = pure (n, pure TDate)
fromArg (ICU.Arg n ICU.Time {})        = pure (n, pure TDate)
fromArg (ICU.Arg n (ICU.Plural x))     = fromPlural n x
fromArg (ICU.Arg n (ICU.Select cs mw)) = (n, pure t) : (fromSelectCase =<< toList cs) <> foldMap fromSelectWildcard mw
  -- When there's no wildcard case we can compile to a union of string literals.
  where t = case mw of
              Just _  -> TUniIn TStr
              Nothing -> TStrLitUnion $ caseLit <$> cs
        caseLit (ICU.SelectCase x _) = x
fromArg (ICU.Arg n (ICU.Callback xs))  = (n, pure TEndo) : (fromToken =<< xs)

fromPlural :: Text -> ICU.Plural -> Args
fromPlural n (ICU.Cardinal (ICU.LitPlural ls mw))      = (n, pure t) : (fromExactPluralCase =<< toList ls) <> foldMap fromPluralWildcard mw
  -- When there's no wildcard case we can compile to a union of number literals.
  where t = case mw of
              Just _  -> TNum
              Nothing -> TNumLitUnion $ caseLit <$> ls
        caseLit (ICU.PluralCase (ICU.PluralExact x) _) = x
fromPlural n (ICU.Cardinal (ICU.RulePlural rs w))      = (n, pure TNum) : (fromRulePluralCase =<< toList rs) <> fromPluralWildcard w
fromPlural n (ICU.Cardinal (ICU.MixedPlural ls rs w))  = (n, pure TNum) : (fromExactPluralCase =<< toList ls) <> (fromRulePluralCase =<< toList rs) <> fromPluralWildcard w
fromPlural n (ICU.Ordinal (ICU.OrdinalPlural ls rs w)) = (n, pure TNum) : (fromExactPluralCase =<< ls) <> (fromRulePluralCase =<< toList rs) <> fromPluralWildcard w

fromExactPluralCase :: ICU.PluralCase ICU.PluralExact -> Args
fromExactPluralCase (ICU.PluralCase (ICU.PluralExact _) xs) = fromToken =<< xs

fromRulePluralCase :: ICU.PluralCase ICU.PluralRule -> Args
fromRulePluralCase (ICU.PluralCase _ xs) = fromToken =<< xs

fromPluralWildcard :: ICU.PluralWildcard -> Args
fromPluralWildcard (ICU.PluralWildcard xs) = fromToken =<< xs

fromSelectCase :: ICU.SelectCase -> Args
fromSelectCase (ICU.SelectCase _ xs) = fromToken =<< xs

fromSelectWildcard :: ICU.SelectWildcard -> Args
fromSelectWildcard (ICU.SelectWildcard xs) = fromToken =<< xs
