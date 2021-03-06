{-# LANGUAGE OverloadedStrings #-}

module Generators ( genTerm
                  , genProgram
                  ) where

import qualified Data.ByteString.Lazy         as BSL
import           Hedgehog                     hiding (Size, Var)
import qualified Hedgehog.Gen                 as Gen
import qualified Hedgehog.Range               as Range
import           Language.PlutusCore
import           Language.PlutusCore.Constant
import           Language.PlutusCore.Pretty

genVersion :: MonadGen m => m (Version ())
genVersion = Version () <$> int' <*> int' <*> int'
    where int' = Gen.integral_ (Range.linear 0 10)

genTyName :: MonadGen m => m (TyName ())
genTyName = TyName <$> genName

-- TODO make this robust against generating identfiers such as "fix"?
genName :: MonadGen m => m (Name ())
genName = Name () <$> name' <*> int'
    where int' = Unique <$> Gen.int (Range.linear 0 3000)
          name' = Gen.filter (\n -> not (isKw n || isBuiltin n)) (Gen.text (Range.linear 1 20) Gen.lower)
          isKw "abs"        = True
          isKw "lam"        = True
          isKw "ifix"       = True
          isKw "fun"        = True
          isKw "all"        = True
          isKw "bytestring" = True
          isKw "integer"    = True
          isKw "size"       = True
          isKw "type"       = True
          isKw "program"    = True
          isKw "con"        = True
          isKw "iwrap"      = True
          isKw "builtin"    = True
          isKw "unwrap"     = True
          isKw "error"      = True
          isKw _            = False
          isBuiltin n = n `elem` fmap prettyText allBuiltinNames

simpleRecursive :: MonadGen m => [m a] -> [m a] -> m a
simpleRecursive = Gen.recursive Gen.choice

genKind :: MonadGen m => m (Kind ())
genKind = simpleRecursive nonRecursive recursive
    where nonRecursive = pure <$> sequence [Type, Size] ()
          recursive = [KindArrow () <$> genKind <*> genKind]

genBuiltinName :: MonadGen m => m BuiltinName
genBuiltinName = Gen.element allBuiltinNames

genBuiltin :: MonadGen m => m (Builtin ())
genBuiltin = BuiltinName () <$> genBuiltinName

genConstant :: MonadGen m => m (Constant ())
genConstant = Gen.choice [genInt, genSize, genBS]
    where int' = Gen.integral_ (Range.linear (-10000000) 10000000)
          size' = Gen.integral_ (Range.linear 1 10)
          string' = BSL.fromStrict <$> Gen.utf8 (Range.linear 0 40) Gen.unicode
          genInt = makeAutoSizedBuiltinInt <$> int'
          genSize = BuiltinSize () <$> size'
          genBS = BuiltinBS () <$> size' <*> string'

genType :: MonadGen m => m (Type TyName ())
genType = simpleRecursive nonRecursive recursive
    where varGen = TyVar () <$> genTyName
          funGen = TyFun () <$> genType <*> genType
          lamGen = TyLam () <$> genTyName <*> genKind <*> genType
          forallGen = TyForall () <$> genTyName <*> genKind <*> genType
          applyGen = TyApp () <$> genType <*> genType
          numGen = TyInt () <$> Gen.integral (Range.linear 0 256)
          recursive = [funGen, applyGen]
          nonRecursive = [varGen, lamGen, forallGen, numGen]

genTerm :: MonadGen m => m (Term TyName Name ())
genTerm = simpleRecursive nonRecursive recursive
    where varGen = Var () <$> genName
          absGen = TyAbs () <$> genTyName <*> genKind <*> genTerm
          instGen = TyInst () <$> genTerm <*> genType
          lamGen = LamAbs () <$> genName <*> genType <*> genTerm
          applyGen = Apply () <$> genTerm <*> genTerm
          unwrapGen = Unwrap () <$> genTerm
          wrapGen = IWrap () <$> genType <*> genType <*> genTerm
          errorGen = Error () <$> genType
          recursive = [absGen, instGen, lamGen, applyGen, unwrapGen, wrapGen]
          nonRecursive = [varGen, Constant () <$> genConstant, Builtin () <$> genBuiltin, errorGen]

genProgram :: MonadGen m => m (Program TyName Name ())
genProgram = Program () <$> genVersion <*> genTerm
