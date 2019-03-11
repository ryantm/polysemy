{-# LANGUAGE BlockArguments             #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE QuantifiedConstraints      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE ViewPatterns               #-}
{-# OPTIONS_GHC -Wall                   #-}

module Lib where


import qualified Control.Exception as X
import           Control.Monad
import qualified Control.Monad.Trans.Except as E
import           Data.OpenUnion.Internal
import           Eff.Type
import           StateT


data State s (m :: * -> *) a where
  Get :: State s m s
  Put :: s -> State s m ()


data Error e (m :: * -> *) a where
  Throw :: e -> Error e m a
  Catch :: m a -> (e -> m a) -> Error e m a


data Scoped (m :: * -> *) a where
  Scoped :: m () -> m a -> Scoped m a


data Bracket (m :: * -> *) a where
  Bracket
      :: m a
      -> (a -> m ())
      -> (a -> m r)
      -> Bracket m r


runBracket
    :: forall r a
     . Member (Lift IO) r
    => (Eff r ~> IO)
    -> Eff (Bracket ': r) a
    -> Eff r a
runBracket finish = interpret $ \start continue -> \case
  Bracket alloc dealloc use -> sendM $
    X.bracket
      (finish $ start alloc)
      (finish . continue dealloc)
      (finish . continue use)


interpret
    :: (forall m tk
           . Functor tk
          => (m ~> Eff r .: tk)
          -> (forall a b. (a -> m b) -> tk a -> Eff r (tk b))
          -> e m
          ~> Eff r .: tk
       )
    -> Eff (e ': r)
    ~> Eff r
interpret f (Freer m) = m $ \u ->
  case decomp u of
    Left  x -> liftEff $ hoist (interpret f) x
    Right (Yo e tk nt z) -> fmap z $
      f (interpret f . nt . (<$ tk))
        (\ff -> interpret f . nt . fmap ff)
        e


interpretLift
    :: (e ~> Eff r)
    -> Eff (Lift e ': r)
    ~> Eff r
interpretLift f (Freer m) = m $ \u ->
  case decomp u of
    Left  x -> liftEff $ hoist (interpretLift f) x
    Right (Yo (Lift e) tk _ z) ->
      fmap (z . (<$ tk)) $ f e


runState :: forall s r a. s -> Eff (State s ': r) a -> Eff r (s, a)
runState s = flip runStateT s . go
  where
    go :: forall x. Eff (State s ': r) x -> StateT s (Eff r) x
    go (Freer m) = m $ \u ->
      case decomp u of
        Left x -> StateT $ \s' ->
          liftEff . weave (s', ())
                          (uncurry (flip runStateT))
                  $ hoist go x
        Right (Yo Get sf nt f) -> fmap f $ do
          s' <- get
          go $ nt $ pure s' <$ sf
        Right (Yo (Put s') sf nt f) -> fmap f $ do
          put s'
          go $ nt $ pure () <$ sf


runError :: forall e r a. Eff (Error e ': r) a -> Eff r (Either e a)
runError = E.runExceptT . go
  where
    go :: forall x. Eff (Error e ': r) x -> E.ExceptT e (Eff r) x
    go (Freer m) = m $ \u ->
      case decomp u of
        Left x -> E.ExceptT  $
          liftEff . weave (Right ()) (either (pure . Left) E.runExceptT)
                  $ hoist go x
        Right (Yo (Throw e) _ _ _) -> E.throwE e
        Right (Yo (Catch try handle) sf nt f) -> fmap f $ E.ExceptT $ do
          ma <- runError $ nt $ (try <$ sf)
          case ma of
            Right _ -> pure ma
            Left e -> do
              runError $ nt $ (handle e <$ sf)

