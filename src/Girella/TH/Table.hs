{-# LANGUAGE LambdaCase #-}
module Girella.TH.Table
  ( -- * TH End points
    makeTypes
  , makeTable
  , makeAdaptorAndInstance
  -- * TH dependencien from this package
  , To
  , optionalColumn
  -- * Re-exported TH dependencies
  , Table (Table)
  , Column
  , dimap
  , ProductProfunctor
  , Nullable
  , p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12, p13, p14, p15, p16
  ) where

import Control.Monad ((<=<))
import Data.Char (isUpper, toLower)
import Data.Foldable (foldl')
import Data.Generics.Uniplate.Data (transformBi)
import Data.Profunctor (dimap)
import Data.Profunctor.Product (ProductProfunctor, p0, p1, p10, p11, p12, p13, p14, p15, p16, p2,
                                p3, p4, p5, p6, p7, p8, p9)
import Data.Profunctor.Product.TH (makeAdaptorAndInstance)
import Language.Haskell.TH.Syntax
import Opaleye.Column (Column, Nullable)
import Opaleye.Table (Table (Table))

import Girella.TH.Util (ambiguateName, simpleName, ty)
import Girella.Table (optionalColumn)
import Girella.To (To)

makeTypes :: Q [Dec] -> Q [Dec]
makeTypes = (fmap concat . mapM makeType =<<)

makeType :: Dec -> Q [Dec]
makeType = \case
  DataD [] origTypeName [] [RecC recConName vtys] ds -> return [dataDecl, aliasO, aliasH, toInstance]
    where
      dataName = (`appendToName` "P") $ ambiguateName origTypeName
      recName = ambiguateName recConName
      synNameO = ambiguateName origTypeName
      synNameH = (`appendToName` "H") $ ambiguateName origTypeName
      appendToName :: Name -> String -> Name
      appendToName (Name (OccName occ) ns) s = OccName (occ ++ s) `Name` ns
      tvars :: [Name]
      tvars = map (simpleName . (:[])) $ take (length vtys) ['a'..'z']
      ttys :: [Type]
      ttys = map (\(_,_,tp) -> tp) vtys
      ttysO :: [Type]
      ttysO = map pgRep ttys
        where
          pgRep = \case
            n@(ConT (Name (OccName "Nullable") _)) `AppT` i -> n `AppT` i
            i                                               -> i
      ttysH :: [Type]
      ttysH = map replaceNullable ttys
        where
          replaceNullable :: Type -> Type
          replaceNullable = transformBi $ \case
            Name (OccName "Nullable") _ -> mkName "Maybe"
            s -> s

      dataDecl = DataD [] dataName (map PlainTV tvars) [RecC recName (zipWith f tvars vtys) ] ds
        where
          f :: Name -> VarStrictType -> VarStrictType
          f c (n,s,_) = (ambiguateName n, s, VarT c)

      aliasO = TySynD synNameO [] $ foldl' AppT (ConT dataName) ttysO
      aliasH = TySynD synNameH [] $ foldl' AppT (ConT dataName) ttysH

      toInstance = TySynInstD (simpleName "To")
                     (TySynEqn [typ, lhs] rhs)
        where
          typ, lhs, rhs :: Type
          typ = VarT (simpleName "typ")
          lhs = foldl' AppT (ConT dataName) $ map VarT tvars
          rhs = foldl' AppT (ConT dataName) $ map (AppT typ . VarT) tvars

  _ -> error "This is not a good looking data type"

makeTable :: String -> Name -> Name -> Q [Dec]
makeTable tableName pName = f <=< reify
  where
    f :: Info -> Q [Dec]
    f = \case
      TyConI (DataD [] _dataName _tvb [RecC recordName vsts] _deriv) -> return [tableSig, table, emptyUpdateSig, emptyUpdateBody]
        where
         tableSig = SigD (simpleName "table") tableTy
           where
             tableTy :: Type
             tableTy = ty "Table" `AppT` tbm `AppT` tb
               where
                 tbm = ty "To" `AppT` ty "Maybe"  `AppT` tb
                 tb  = ty "To" `AppT` ty "Column" `AppT` ConT (ambiguateName recordName)
         table = FunD (simpleName "table") [Clause [] (NormalB e) []]
           where
             e :: Exp
             e = AppE (AppE (ConE (simpleName "Table")) (LitE $ StringL tableName)) wireRec
             wireRec :: Exp
             wireRec = AppE (VarE pName) (RecConE recordName $ map field vsts)
             field :: VarStrictType -> FieldExp
             field (nm, _, _) = (nm, AppE (VarE (simpleName "optionalColumn")) (LitE . StringL $ columnName nm))
             columnName :: Name -> String
             columnName (Name (OccName occ) _) = removeApostrophes . concatMap underscore $ occ
             underscore :: Char -> String
             underscore c
               | isUpper c = ['_', toLower c]
               | otherwise = [c]
             removeApostrophes = filter (/= '\'')
         -- TODO opa ConT recordName isn't valid, it just happens to be the
         -- same as the name of the type alias so ambiguateName just
         -- acts as unsafeCoerce here.
         emptyUpdateSig = SigD (simpleName "emptyUpdate") (ty "To" `AppT` ty "Maybe" `AppT` (ty "To" `AppT` ty "Column" `AppT` ConT (ambiguateName recordName)))
         emptyUpdateBody = FunD (simpleName "emptyUpdate") [Clause [] (NormalB e) []]
           where
             e :: Exp
             e = foldl' AppE (ConE recordName) . map (const . ConE $ simpleName "Nothing") $ vsts

      _ -> error "makeTable: I need one record"
