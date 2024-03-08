{-# LANGUAGE DeriveAnyClass       #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE DerivingStrategies   #-}
{-# LANGUAGE ExplicitNamespaces   #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE MonoLocalBinds       #-}
{-# LANGUAGE PolyKinds            #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE StandaloneDeriving   #-}
{-# LANGUAGE UndecidableInstances #-}

module Mock
    ( prop_sequential_mock
    , prop_parallel_mock
    , prop_nparallel_mock
    )
    where

import           Control.Concurrent
import           GHC.Generics
                   (Generic, Generic1)
import           Prelude
import           Test.QuickCheck
import           Test.QuickCheck.Monadic
                   (monadicIO)
import           Test.StateMachine
import           Test.StateMachine.DotDrawing
import           Test.StateMachine.TreeDiff
import qualified Test.StateMachine.Types.Rank2 as Rank2

------------------------------------------------------------------------

data Command r
  = Create
  deriving stock (Eq, Generic1)
  deriving anyclass (Rank2.Functor, Rank2.Foldable, Rank2.Traversable, CommandNames)

deriving stock instance Show (Command Symbolic)
deriving stock instance Read (Command Symbolic)
deriving stock instance Show (Command Concrete)

data Response r
  = Created (Reference Int r)
  | NotCreated
  deriving stock (Eq, Generic1)
  deriving anyclass Rank2.Foldable

deriving stock instance Show (Response Symbolic)
deriving stock instance Read (Response Symbolic)
deriving stock instance Show (Response Concrete)

data Model r = Model {
      refs :: [Reference Int r]
    , c    :: Int
    }
  deriving stock (Generic, Show)

instance ToExpr (Model Symbolic)
instance ToExpr (Model Concrete)

initModel :: Model r
initModel = Model [] 0

transition :: Model r -> Command r -> Response r -> Model r
transition m@Model{..} cmd resp = case (cmd, resp, c) of
  (Create, Created ref, 0) -> Model (ref : refs) 1
  (Create, _, _)           -> m

precondition :: Model Symbolic -> Command Symbolic -> Logic
precondition _ cmd = case cmd of
    Create        -> Top

postcondition :: Model Concrete -> Command Concrete -> Response Concrete -> Logic
postcondition _ _ _ = Top

semantics :: MVar Int -> Command Concrete -> IO (Response Concrete)
semantics counter cmd = case cmd of
  Create        -> do
    c <- modifyMVar counter (\x -> return (x + 1, x))
    case c of
        0 -> return $ Created $ reference c
        _ -> return NotCreated

mock :: Model Symbolic -> Command Symbolic -> GenSym (Response Symbolic)
mock Model{..} cmd = case (cmd, c) of
  (Create, 0) -> Created   <$> genSym
  (Create, _) -> return NotCreated

generator :: Model Symbolic -> Maybe (Gen (Command Symbolic))
generator _            = Just $ frequency
    [(1, return Create)]

shrinker :: Model Symbolic -> Command Symbolic -> [Command Symbolic]
shrinker _ _ = []

sm :: IO (StateMachine Model Command IO Response)
sm = do
  counter <- newMVar 0
  pure $ StateMachine initModel transition precondition postcondition
        Nothing generator shrinker (semantics counter) mock noCleanup Nothing

smUnused :: StateMachine Model Command IO Response
smUnused = StateMachine initModel transition precondition postcondition
        Nothing generator shrinker e mock noCleanup Nothing
  where
    e = error "SUT must not be used"

prop_sequential_mock :: Property
prop_sequential_mock = forAllCommands smUnused Nothing $ \cmds -> monadicIO $ do
  (hist, _model, res, _prop) <- runCommandsWithSetup sm cmds
  prettyCommands smUnused hist (res === Ok)

prop_parallel_mock :: Property
prop_parallel_mock = forAllParallelCommands smUnused Nothing $ \cmds -> monadicIO $ do
    ret <- runParallelCommandsWithSetup sm cmds
    prettyParallelCommandsWithOpts cmds opts ret
      where opts = Just $ GraphOptions "mock-test-output.png" Png

prop_nparallel_mock :: Property
prop_nparallel_mock = forAllNParallelCommands smUnused 3 $ \cmds -> monadicIO $ do
    ret <- runNParallelCommandsWithSetup sm cmds
    prettyNParallelCommandsWithOpts cmds opts ret
      where opts = Just $ GraphOptions "mock-np-test-output.png" Png
