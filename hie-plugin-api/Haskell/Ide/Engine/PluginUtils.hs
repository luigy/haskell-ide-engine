{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
module Haskell.Ide.Engine.PluginUtils
  (
    getParams
  , mapEithers
  , missingParameter
  , incorrectParameter
  , validatePlugins
  , PluginDescriptionError(..)
  , ParamCollision
  ) where

import           Data.Aeson

import           Data.List
import           Data.Maybe
import           Data.Monoid
import           Data.Vinyl
import           Haskell.Ide.Engine.PluginDescriptor
import qualified Data.Map as Map
import qualified Data.Text as T
import           Prelude hiding (log)

-- ---------------------------------------------------------------------

-- TODO: should this be in the haskell-ide-plugins-api

-- |If all the listed params are present in the request resturn their values,
-- else return an error message.
getParams :: forall r ts. (ValidResponse r) =>
  Rec TaggedParamId ts -> IdeRequest -> Either (IdeResponse r) (Rec ParamVal ts)
getParams params req = go params
  where
    go :: forall r ts. (ValidResponse r) =>
      Rec TaggedParamId ts -> Either (IdeResponse r) (Rec ParamVal ts)
    go RNil = Right RNil
    go (x:&xs) = case go xs of
                    Left err -> Left err
                    Right ys -> case checkOne x of
                                  Left err -> Left err
                                  Right y -> Right (y:&ys)
    checkOne :: forall r t. (ValidResponse r) =>
      TaggedParamId t -> Either (IdeResponse r) (ParamVal t)
    checkOne (IdText param) = case Map.lookup param (ideParams req) of
      Just (ParamTextP v)  -> Right (ParamText v)
      _ -> Left (missingParameter param)
    checkOne (IdFile param) = case Map.lookup param (ideParams req) of
      Just (ParamFileP v)  -> Right (ParamFile v)
      _ -> Left (missingParameter param)
    checkOne (IdPos param) = case Map.lookup param (ideParams req) of
      Just (ParamPosP v)  -> Right (ParamPos v)
      _ -> Left (missingParameter param)


-- ---------------------------------------------------------------------
-- courtesy of http://stackoverflow.com/questions/19891061/mapeithers-function-in-haskell
mapEithers :: (a -> Either b c) -> [a] -> Either b [c]
mapEithers f (x:xs) = case mapEithers f xs of
                        Left err -> Left err
                        Right ys -> case f x of
                                      Left err -> Left err
                                      Right y -> Right (y:ys)
mapEithers _ _ = Right []

-- ---------------------------------------------------------------------
-- Helper functions for errors
-- ---------------------------------------------------------------------

-- Missing parameter error
missingParameter :: forall r. (ValidResponse r) => ParamId -> IdeResponse r
missingParameter param = IdeResponseFail (IdeError MissingParameter
            ("need `" <> param <> "` parameter")
            (Just $ toJSON param))

-- Incorrect parameter error
incorrectParameter :: forall r a b. (ValidResponse r,Show a,Show b)
  => ParamId -> a -> b -> IdeResponse r
incorrectParameter name expected value = IdeResponseFail
    (IdeError IncorrectParameterType
    ("got wrong parameter type for `" <> name <> "`, expected: " <>
      T.pack (show expected) <>" , got:" <> T.pack (show value))
    (Just $ object ["param" .= toJSON name,"expected".= toJSON (show expected),
      "value" .= toJSON (show value)]))


-- ---------------------------------------------------------------------

data ParamCollision = ParamCollision ParamLocation ParamCollisionInfo deriving (Eq, Show)
data ParamLocation = ParamLocation PluginId CommandName ParamName deriving (Eq, Show)
data ParamCollisionInfo = AdditionalParam ParamDescription | ContextParam AcceptedContext ParamDescription deriving (Eq, Show)
type AdditionalParams = [ParamDescription]
type ContextParams = [(AcceptedContext, ParamDescription)]

paramNameCollisions :: Plugins -> [ParamCollision]
paramNameCollisions plugins =
  concatMap (\(plId, plDesc) ->
    concatMap (paramNameCollisionsForCmd plId . cmdDesc) (pdCommands plDesc)) (Map.toList plugins)

paramNameCollisionsForCmd :: PluginId -> CommandDescriptor -> [ParamCollision]
paramNameCollisionsForCmd plId cmdDescriptor =
  let collidingParamNames = findCollidingParamNames cmdDescriptor
      location = ParamLocation plId (cmdName cmdDescriptor)
      collisionSources =
        concatMap (\paramName ->
          map (ParamCollision (location paramName))
          (paramsByName cmdDescriptor paramName))
        collidingParamNames
   in collisionSources

-- find all the parameters within the CommandDescriptor that goes by the given ParamName
paramsByName :: CommandDescriptor -> ParamName -> [ParamCollisionInfo]
paramsByName cmdDesc paramName =
  undefined

findCollidingParamNames :: CommandDescriptor -> [ParamName]
findCollidingParamNames = -- TODO: remember that collisions within AcceptedContext should not count
  undefined

data PluginDescriptionError =
 PluginDescriptionError {
   pdeCollisions :: [ParamCollision]
 , pdeErrorMsg :: String
 } deriving (Eq, Show)

validatePlugins :: Plugins -> Maybe PluginDescriptionError
validatePlugins plugins =
 case paramNameCollisions plugins of
    [] -> Nothing
    collisions -> Just PluginDescriptionError {
         pdeCollisions = collisions
       , pdeErrorMsg = formatParamNameCollisionErrorMsg collisions
     }

formatParamNameCollisionErrorMsg :: [ParamCollision] -> String
formatParamNameCollisionErrorMsg = show -- TODO
