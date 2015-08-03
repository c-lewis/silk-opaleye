{-# LANGUAGE NoImplicitPrelude #-}
module Girella.TH.Column
  ( -- * TH end points
    mkId
  , makeColumnInstances
    -- * TH dependencies defined here
  , fromFieldAux
    -- * Re-exported TH dependencies
  , Typeable
  , Default (def)
  , ShowConstant (..)
  , FromField (fromField)
  , QueryRunnerColumnDefault (..)
  , Nullable
  , Column
  , fieldQueryRunnerColumn
  , unsafeCoerceColumn
  ) where

import Prelude.Compat

import Control.Monad ((<=<))
import Data.Data (Typeable)
import Data.Maybe (mapMaybe)
import Data.Profunctor.Product.Default (Default (def))
import Data.String.Conversions (StrictByteString, cs)
import Database.PostgreSQL.Simple.FromField (Conversion, Field, FromField (..), ResultError (..),
                                             returnError)
import Language.Haskell.TH
import Opaleye.Column (Column, Nullable, unsafeCoerceColumn)
import Opaleye.RunQuery (fieldQueryRunnerColumn)
import Opaleye.RunQuery (QueryRunnerColumnDefault (..))
import Safe (headNote)

import Girella.Compat (classP_, equalP_)
import Girella.ShowConstant (ShowConstant (..))
import Girella.TH.Util (getConNameTy, ty)

-- TODO This assumes the destructor is named unId, can be changed to a pattern match.
-- TODO It's probably too lenient with input as well, only newtypes or constructors with one field are allowed.
mkId :: Name -> Q [Dec]
mkId = return . either error id <=< f <=< reify
  where
    f :: Info -> Q (Either String [Dec])
    f i = case i of
      TyConI (NewtypeD _ctx tyName _tyVars@[] con _names) ->
        case getConNameTy con of
          Left err      -> return $ Left err
          Right (conName, innerTy) -> Right <$> g tyName conName (headNote "Girella.TH.Column.mkId innerTy" innerTy)
      TyConI NewtypeD{} -> return $ Left "Type variables aren't allowed"
      _  -> return $ Left "Must be a newtype"

    g :: Name -> Name -> Type -> Q [Dec]
    g tyName _conName innerTy = do
      let x = [unsafeIdSig, unsafeId, unsafeIdSig', unsafeId']
      y <- makeColumnInstancesInternal tyName innerTy (mkName "unId") (mkName "unsafeId'")
      return $ x ++ y
      where
        unsafeIdSig, unsafeId, unsafeIdSig', unsafeId' :: Dec
        unsafeIdSig = SigD (mkName "unsafeId") $ ArrowT `AppT` innerTy `AppT` ty "Id"
        unsafeId  = plainFun (mkName "unsafeId")  $ ConE (mkName "Id")
        unsafeIdSig' = SigD (mkName "unsafeId'") $ ArrowT `AppT` innerTy `AppT` (ty "Maybe" `AppT` ty "Id")
        unsafeId' = plainFun (mkName "unsafeId'") $ VarE (mkName ".") `AppE` ConE (mkName "Just") `AppE` ConE (mkName "Id")
        plainFun n e = FunD n [Clause [] (NormalB e) []]

makeColumnInstances :: Name -> Name -> Name -> Name -> Q [Dec]
makeColumnInstances tyName innerTyName toDb fromDb = makeColumnInstancesInternal tyName (ConT innerTyName) toDb fromDb

makeColumnInstancesInternal :: Name -> Type -> Name -> Name -> Q [Dec]
makeColumnInstancesInternal tyName innerTy toDb fromDb = do
  tvars <- getTyVars tyName
  let predCond = map (classP_ (mkName "Typeable") . (:[])) tvars
  let outterTy = foldl AppT (ConT tyName) tvars
  return $ map ($ (predCond, outterTy)) [fromFld, showConst, queryRunnerColumn]
  where
    fromFld (predCond, outterTy)
      = InstanceD
          predCond
          (ConT (mkName "FromField") `AppT` outterTy)
          [ FunD (mkName "fromField")
            [ Clause [] (NormalB $ VarE (mkName "fromFieldAux") `AppE` VarE fromDb) [] ]
          ]
    showConst (_, outterTy)
      = InstanceD
          []
          (ConT (mkName "ShowConstant") `AppT` outterTy)
          [ TySynInstD (mkName "PGRep") (TySynEqn [outterTy] (ConT (mkName "PGRep") `AppT` innerTy))
          , FunD (mkName "constant")
            [ Clause []
              (NormalB $ InfixE
               (Just (VarE (mkName "unsafeCoerceColumn")))
               (VarE (mkName "."))
               (Just (InfixE (Just (VarE (mkName "constant"))) (VarE (mkName ".")) (Just (VarE toDb))))
              )
              []
            ]
          ]
    queryRunnerColumn (predCond, outterTy)
      = InstanceD
          (equalP_ (ConT (mkName "PGRep") `AppT` outterTy) tyVar : predCond)
          (ConT (mkName "QueryRunnerColumnDefault") `AppT` outterTy `AppT` outterTy)
          [ FunD
            (mkName "queryRunnerColumnDefault")
            [ Clause [] (NormalB $ VarE $ mkName "fieldQueryRunnerColumn") [] ]
          ]
      where tyVar = VarT $ mkName "a"

getTyVars :: Name -> Q [Type]
getTyVars n = do
  info <- reify n
  return . mapMaybe onlyPlain $ case info of
    TyConI (DataD    _ _ tvars _ _) -> tvars
    TyConI (NewtypeD _ _ tvars _ _) -> tvars
    TyConI (TySynD   _   tvars _  ) -> tvars
    _                               -> []
  where
    onlyPlain (PlainTV nv) = Just $ VarT nv
    onlyPlain _            = Nothing

fromFieldAux :: (FromField a, Typeable b) => (a -> Maybe b) -> Field -> Maybe StrictByteString -> Conversion b
fromFieldAux fromDb f mdata = case mdata of
  Just dat -> maybe (returnError ConversionFailed f (cs dat)) return . fromDb =<< fromField f mdata
  Nothing  -> returnError UnexpectedNull f ""
