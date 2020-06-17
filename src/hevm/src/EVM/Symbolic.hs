{-# Language GADTs #-}
{-# Language NamedFieldPuns #-}
{-# Language DataKinds #-}
{-# Language OverloadedStrings #-}
{-# Language TypeApplications #-}

module EVM.Symbolic where

import Control.Lens
import EVM hiding (Query, push)
import qualified EVM as EVM
import EVM.Exec
import EVM.Op
import Options.Generic as Options
import qualified EVM.Fetch as Fetch
import EVM.ABI
import EVM.Stepper (Stepper)
import qualified EVM.Stepper as Stepper
import qualified Control.Monad.Operational as Operational
import EVM.Types
import EVM.Format
import EVM.Keccak
import EVM.Solidity
import EVM.Concrete (createAddress, SymWord(..), sw256)
import qualified EVM.FeeSchedule as FeeSchedule
import Data.SBV.Trans.Control hiding (sat)
import Data.SBV.Trans
import Data.SBV.Control (registerUISMTFunction)
import Data.SBV.Internals (sendStringToSolver)
import Data.SBV hiding (runSMT, newArray_, addAxiom)

import Control.Monad.IO.Class
import GHC.TypeNats
import Data.Vector        (Vector, toList)
import Control.Monad.State.Class (MonadState)
import qualified Control.Monad.State.Class as State
import Data.ByteString.Lazy (toStrict, fromStrict)
import Data.ByteString (ByteString, pack, null)
import qualified Data.ByteString as BS
import Data.Text (Text)
import Data.Binary.Put    (runPut)
import Data.Binary.Get    (runGet)
import Control.Monad.State.Strict (runStateT, runState, execState, unless, StateT, forM, put, lift, foldM, liftM)
import Control.Applicative
import Data.Maybe (isJust, fromJust)
import Data.Foldable (fold)

mkSymbolicContract :: ContractCode -> Storage -> Contract
mkSymbolicContract theContractCode store = Contract
  { _contractcode = theContractCode
  , _codehash =
    if BS.null theCode then 0 else
      keccak (stripBytecodeMetadata theCode)
  , _storage  = store
  , _balance  = 0
  , _nonce    = 0
  , _opIxMap  = mkOpIxMap theCode
  , _codeOps  = mkCodeOps theCode
  , _external = False
  , _origStorage = mempty
  } where theCode = case theContractCode of
            InitCode b    -> b
            RuntimeCode b -> b

abstractVM :: Maybe Text -> ByteString -> StorageModel -> Query VM
abstractVM signature' x storagemodel = do
  (cd', cdlen, cdconstraint) <-
    case signature' of
      Nothing -> do cd <- sbytes256
                    len <- freshVar_
                    return (cd, len, len .<= 1024)
      Just sign -> do (input,len) <- symAbiArg $ fromJust (parseFunArgs sign)
                      return (litBytes (sig sign) <> input, len + 4, sTrue)
  symstore <- case storagemodel of
    SymbolicS -> Symbolic <$> freshArray_ Nothing
    InitialS -> Symbolic <$> freshArray_ (Just 0)
    ConcreteS -> return $ Concrete mempty
  c <- SAddr <$> freshVar_
  return $ loadSymVM x symstore c (cd', cdlen) & over pathConditions ((<>) [cdconstraint])

loadSymVM :: ByteString -> Storage -> SAddr -> ([SWord 8], SWord 32) -> VM
loadSymVM x initStore addr calldata =
    (makeVm $ VMOpts
    { vmoptContract = mkSymbolicContract (RuntimeCode x) initStore
    , vmoptCalldata = calldata
    , vmoptValue = 0
    , vmoptAddress = createAddress ethrunAddress 1
    , vmoptCaller = addr
    , vmoptOrigin = ethrunAddress --todo: generalize
    , vmoptCoinbase = 0
    , vmoptNumber = 0
    , vmoptTimestamp = 0
    , vmoptBlockGaslimit = 0
    , vmoptGasprice = 0
    , vmoptDifficulty = 0
    , vmoptGas = 0xffffffffffffffff
    , vmoptGaslimit = 0xffffffffffffffff
    , vmoptMaxCodeSize = 0xffffffff
    , vmoptSchedule = FeeSchedule.istanbul
    , vmoptCreate = False
    }) & set (env . contracts . at (createAddress ethrunAddress 1))
             (Just (mkSymbolicContract (RuntimeCode x) initStore))


sbytes32, sbytes64, sbytes128, sbytes256, sbytes512, sbytes1024 :: Query ([SWord 8])
sbytes32 =  toBytes <$> freshVar_ @ (WordN 256)
sbytes64 = liftA2 (<>) sbytes32 sbytes32
sbytes128 = liftA2 (<>) sbytes64 sbytes64
sbytes256 = liftA2 (<>) sbytes128 sbytes128
sbytes512 = liftA2 (<>) sbytes256 sbytes256
sbytes1024 = liftA2 (<>) sbytes512 sbytes512

symAbiArg :: AbiType -> Query ([SWord 8], SWord 32)
-- We don't assume input types are restricted to their proper range here;
-- such assumptions should instead be given as preconditions.
-- This could catch some interesting calldata mismanagement errors.
symAbiArg (AbiUIntType n) | n `mod` 8 == 0 && n <= 256 = do x <- freshVar_ @ (WordN 256)
                                                            return (toBytes x, 32)
                          | otherwise = error "bad type"

symAbiArg (AbiIntType n)  | n `mod` 8 == 0 && n <= 256 = do x <- freshVar_ @ (WordN 256)
                                                            return (toBytes x, 32)
                          | otherwise = error "bad type"

symAbiArg AbiAddressType = do x <- freshVar_ @ (WordN 256)
                              return (toBytes x, 32)

symAbiArg (AbiBytesType n) | n <= 32 = do x <- freshVar_ @ (WordN 256)
                                          return (toBytes x, 32)
                           | otherwise = error "bad type"

-- TODO: is this encoding correct?
symAbiArg (AbiArrayType len typ) = do args <- mapM symAbiArg (replicate len typ)
                                      return (litBytes (encodeAbiValue (AbiUInt 256 (fromIntegral len))) <> (concat $ fst <$> args), 32 + (sum $ snd <$> args))

symAbiArg (AbiTupleType tuple) = do args <- mapM symAbiArg (toList tuple)
                                    return (concat $ fst <$> args, sum $ snd <$> args)
symAbiArg n = error $ "TODO: symbolic abiencoding for" <> show n

-- Interpreter which explores all paths at
-- branching points.
-- returns a list of possible final evm states
interpret
  :: (EVM.Query -> IO (EVM ()))
  -> Maybe Integer --max iterations
  -> Stepper a
  -> StateT VM IO (Either Stepper.Failure [a])
interpret fetcher maxIter =
  eval . Operational.view

  where
    eval
      :: Operational.ProgramView Stepper.Action a
      -> StateT VM IO (Either Stepper.Failure [a])

    eval (Operational.Return x) =
      pure (Right [x])

    eval (action Operational.:>>= k) =
      case action of
        Stepper.Exec ->
          exec >>= interpret fetcher maxIter . k
        Stepper.Run ->
          run >>= interpret fetcher maxIter . k
        Stepper.Option (EVM.PleaseChoosePath continue) ->
          do vm <- State.get
             case maxIter of
               Just maxiter ->
                 let pc' = view (state . pc) vm
                     addr = view (state . contract) vm
                     iters = view (iterations . at (addr, pc') . non 0) vm
                 in if num maxiter <= iters then
                      let Just lastChoice = view (cache . path . at ((addr, pc'), iters - 1)) vm
                      in case lastChoice of
                        -- try something different
                        Known 0 -> State.state (runState (continue 1)) >> interpret fetcher maxIter (k ())
                        Known 1 -> State.state (runState (continue 0)) >> interpret fetcher maxIter (k ())
                        n -> error ("I don't see how this could have happened: " <> show n)
                    else do a <- State.state (runState (continue 0)) >> interpret fetcher maxIter (k ())
                            put vm
                            b <- State.state (runState (continue 1)) >> interpret fetcher maxIter (k ())
                            return $ liftA2 (<>) a b
               Nothing -> do a <- State.state (runState (continue 0)) >> interpret fetcher maxIter (k ())
                             put vm
                             b <- State.state (runState (continue 1)) >> interpret fetcher maxIter (k ())
                             return $ liftA2 (<>) a b
        Stepper.Wait q ->
          do m <- liftIO (fetcher q)
             State.state (runState m) >> interpret fetcher maxIter (k ())
        Stepper.Note _ ->
          -- simply ignore the note here
          interpret fetcher maxIter (k ())
        Stepper.Fail e ->
          pure (Left e)
        Stepper.EVM m ->
          State.state (runState m) >>= interpret fetcher maxIter . k

type Precondition = [SWord 8] -> SBool
type Postcondition = (VM, VM) -> SBool

checkAssert :: ContractCode -> Maybe Integer -> Maybe Text -> Query (Either (VM, [VM]) ByteString)
checkAssert code maxIter signature' = verifyContract code maxIter signature' SymbolicS (const sTrue) (Just checkAssertions)

checkAssertions :: Postcondition
checkAssertions (_, output) = case view result output of
  Just (EVM.VMFailure (EVM.UnrecognizedOpcode 254)) -> sFalse
  _ -> sTrue

data StorageModel = ConcreteS | SymbolicS | InitialS
  deriving (Read, Show)

instance ParseField StorageModel

verifyContract :: ContractCode -> Maybe Integer -> Maybe Text -> StorageModel -> Precondition -> Maybe Postcondition -> Query (Either (VM, [VM]) ByteString)
verifyContract (RuntimeCode runtimecode) maxIter signature' storagemodel pre maybepost = do
    preStateRaw <- abstractVM signature' runtimecode  storagemodel
    let args = drop 4 $ fst $ view (state . calldata) preStateRaw
    -- add the pre condition to the pathconditions to ensure that we are only exploring valid paths
    let preState = over pathConditions ((++) [pre args]) preStateRaw
    verify preState maxIter maybepost

verify :: VM -> Maybe Integer -> Maybe Postcondition -> Query (Either (VM, [VM]) ByteString)
verify preState maxIter maybepost = do
  smtState <- queryState
  results <- io $ fst <$> runStateT (interpret (Fetch.oracle smtState Nothing) maxIter Stepper.runFully) preState
  case (maybepost, results) of
    (Just post, Right res) -> do
      let postC = sOr $ fmap (\postState -> (sAnd (view pathConditions postState)) .&& sNot (post (preState, postState))) res
                  -- is there any path which can possibly violate
                  -- the postcondition?
      resetAssertions
      constrain postC
      io $ putStrLn "checking postcondition..."
      sat <- checkSat
      case sat of
        Unk -> do io $ putStrLn "postcondition query timed out"
                  return $ Left (preState, res)
        Unsat -> do io $ putStrLn "Q.E.D"
                    return $ Left (preState, res)
        Sat -> do io $ putStrLn "post condition violated:"
                  let (calldata', cdlen) = view (state . calldata) preState
                  cdlen <- num <$> getValue cdlen
                  model <- mapM (getValue.fromSized) (take cdlen calldata')
                  return $ Right (pack model)

    (Nothing, Right res) -> do io $ print "Q.E.D"
                               return $ Left (preState, res)

    (_, Left _) -> error "unexpected error during symbolic execution"

equivalenceCheck :: ByteString -> ByteString -> Maybe Integer -> Maybe Text -> Query (Either ([VM], [VM]) ByteString)
equivalenceCheck bytecodeA bytecodeB maxiter signature' = do
  preStateA <- abstractVM signature' bytecodeA SymbolicS
           
  let preself = preStateA ^. state . contract
      precaller = preStateA ^. state . caller
      prestorage = preStateA ^?! env . contracts . ix preself . storage
      (calldata', cdlen) = view (state . calldata) preStateA
      preStateB = loadSymVM bytecodeB prestorage precaller (calldata', cdlen)

  smtState <- queryState
  (aRes, bRes) <- both (\x -> io $ fst <$> runStateT (interpret (Fetch.oracle smtState Nothing) maxiter Stepper.runFully) x)
    (preStateA, preStateB)
  case (aRes, bRes) of
    (Left errA, Right _) -> error $ "A Failed: " <> show errA
    (Right _, Left errB) -> error $ "B Failed: " <> show errB
    (Left errA, Left errB) -> error $ "A Failed: " <> show errA <> "\nand B Failed:" <> show errB
    (Right aVMs, Right bVMs) -> do
      let differingEndStates = zipWith distinct aVMs bVMs
          distinct a b = let (aPath, bPath) = both' (view pathConditions) (a, b)
                             (aSelf, bSelf) = both' (view (state . contract)) (a, b)
                             (aEnv, bEnv) = both' (view (env . contracts)) (a, b)
                             (aResult, bResult) = both' (view result) (a, b)
                             (Symbolic aStorage, Symbolic bStorage) = (view storage (aEnv ^?! ix aSelf), view storage (bEnv ^?! ix bSelf))
                             differingResults = case (aResult, bResult) of
                               (Just (VMSuccess aOut), Just (VMSuccess bOut)) -> aOut ./= bOut .|| aStorage ./= bStorage .|| fromBool (aSelf /= bSelf)
                               (Just (VMFailure _), Just (VMFailure _)) -> sFalse
                               (Just _, Just _) -> sTrue
                               _ -> error "Internal error during symbolic execution (should not be possible)"
                         in sAnd aPath .&& sAnd bPath .&& differingResults
      -- If there exists a pair of endstates where this is not the case,
      -- the following constraint is satisfiable
      resetAssertions
      constrain $ sOr differingEndStates

      checkSat >>= \case
         Unk -> error "solver said unknown!"
         Sat -> do cdlen <- num <$> getValue cdlen
                   model <- mapM (getValue.fromSized) (take cdlen calldata')
                   return (Right (pack model))
         Unsat -> return $ Left (aVMs, bVMs)


-- prelude plz
both' :: (a -> b) -> (a, a) -> (b, b)
both' f (x, y) = (f x, f y)