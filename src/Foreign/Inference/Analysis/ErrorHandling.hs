{-# LANGUAGE ViewPatterns, RankNTypes, ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric, PatternGuards #-}
{-# LANGUAGE TemplateHaskell #-}
-- | This analysis attempts to automatically identify error-handling
-- code in libraries.
--
-- The error laws are:
--
--  * (Transitive error) If function F returns the result of calling
--    callee C directly, and C has error handling pattern P, then F
--    has error handling pattern P.
--
--  * (Known error) If function F checks the result of calling C for
--    an error condition and performs some action ending in a constant
--    integer error return code, that is error handling code.  Actions
--    are assigning to globals and calling functions. (Note: may need
--    to make this a non-zero return).
--
--  * (Generalize return) If F calls any (all?) of the functions in an
--    error descriptor and then returns a constant int I, I is a new
--    error code used in this library.
--
--  * (Generalize action) If a function F returns a constant int I
--    that is the return code for a known error handling pattern, then
--    the functions called on that branch are a new error handling
--    pattern.
module Foreign.Inference.Analysis.ErrorHandling (
  ErrorSummary,
  Classifier(..),
  ErrorAnalysisOptions(..),
  defaultErrorAnalysisOptions,
  identifyErrorHandling,
  ErrorFuncClass(..),
  FeatureVector,
  featureVectorLength,
  errorHandlingTrainingData
  ) where

import GHC.Generics

import Control.DeepSeq
import Control.DeepSeq.Generics ( genericRnf )
import Control.Lens ( makeLenses, (&), (%~), (^.) )
import Control.Monad.State.Strict
import Control.Monad.Trans.Maybe
import qualified Data.Foldable as F
import Data.HashMap.Strict ( HashMap )
import qualified Data.HashMap.Strict as HM
import Data.IntMap ( IntMap )
import qualified Data.IntMap as IM
import Data.List.NonEmpty ( NonEmpty(..) )
import qualified Data.List.NonEmpty as NEL
import qualified Data.Map as M
import Data.Maybe ( catMaybes, fromMaybe, mapMaybe )
import Data.Monoid
import Data.SBV
import Data.Set ( Set )
import qualified Data.Set as S
import System.IO.Unsafe ( unsafePerformIO )

import LLVM.Analysis
import LLVM.Analysis.BlockReturnValue
import LLVM.Analysis.CDG
import LLVM.Analysis.CFG
import LLVM.Analysis.Dominance

import Foreign.Inference.AnalysisMonad
import Foreign.Inference.Diagnostics
import Foreign.Inference.Interface
import Foreign.Inference.Analysis.IndirectCallResolver
import Foreign.Inference.Analysis.ErrorHandling.SVM

-- import Text.Printf
-- import Debug.Trace
-- debug :: a -> String -> a
-- debug = flip trace

-- | An ErrorDescriptor describes a site in the program handling an
-- error (along with a witness).
data ErrorDescriptor =
  ErrorDescriptor { errorActions :: Set ErrorAction
                  , errorReturns :: ErrorReturn
                  , errorWitnesses :: [Witness]
                  }
  deriving (Eq, Ord, Generic, Show)

instance NFData ErrorDescriptor where
  rnf = genericRnf

-- | The error summary is the type exposed to callers, mapping each
-- function to its error handling methods.
-- type SummaryType = HashMap Function (Set ErrorDescriptor)
data ErrorSummary = ErrorSummary { _errorSummary :: HashMap Function (Set ErrorDescriptor)
                                 , _errorBasicFacts :: BasicFacts
                                 , _errorDiagnostics :: Diagnostics
                                 }
                  deriving (Generic)

$(makeLenses ''ErrorSummary)

instance Eq ErrorSummary where
  (ErrorSummary s1 b1 _) == (ErrorSummary s2 b2 _) = s1 == s2 && b1 == b2

instance Monoid ErrorSummary where
  mempty = ErrorSummary mempty mempty mempty
  mappend (ErrorSummary m1 b1 d1) (ErrorSummary m2 b2 d2) =
    ErrorSummary (HM.union m1 m2) (mappend b1 b2) (mappend d1 d2)

instance NFData ErrorSummary where
  rnf = genericRnf

instance HasDiagnostics ErrorSummary where
  diagnosticLens = errorDiagnostics

data ErrorData =
  ErrorData { indirectCallSummary :: IndirectCallSummary
            }

-- | This is the data we want to bootstrap through the two
-- generalization rules
data ErrorState =
  ErrorState { errorCodes :: Set Int
             , errorFunctions :: Set String
             , successModel :: HashMap Function (Set Int)
             , formulaCache :: HashMap (Function, BasicBlock, Instruction) (Maybe (SInt32 -> SBool))
             }

instance Monoid ErrorState where
  mempty = ErrorState mempty mempty mempty mempty
  mappend (ErrorState c1 f1 s1 fc1) (ErrorState c2 f2 s2 fc2) =
    ErrorState { errorCodes = c1 `mappend` c2
               , errorFunctions = f1 `mappend` f2
               , successModel = HM.unionWith S.union s1 s2
               , formulaCache = HM.union fc1 fc2
               }


type Analysis = AnalysisMonad ErrorData ErrorState

data TrainingWrapper = TrainingWrapper [(Value, FeatureVector)] Diagnostics
instance HasDiagnostics TrainingWrapper where
  diagnosticLens f (TrainingWrapper val d) =
    fmap (\d' -> TrainingWrapper val d') (f d)

errorHandlingTrainingData :: (HasFunction funcLike, HasBlockReturns funcLike,
                              HasDomTree funcLike, HasCDG funcLike,
                              HasCFG funcLike)
                          => [funcLike]
                          -> DependencySummary
                          -> IndirectCallSummary
                          -> [(Value, FeatureVector)]
errorHandlingTrainingData funcLikes ds ics = r
  where
    TrainingWrapper r _ = runAnalysis a ds (ErrorData ics) mempty
    a = do
      res1 <- extractBasicFacts mempty funcLikes
      let base = res1 ^. errorBasicFacts
          res2 = M.toList $ computeFeatures base funcLikes
      return $ TrainingWrapper res2 mempty

-- | FIXME: Provide a classifier where the user supplies a set of
-- error-reporting functions that we can trivially use.  That would
-- be a nice compromise that could remove a lot of guessing.  It would
-- also be easy for library authors.
--
-- Also provide a regex matcher/classifier
data Classifier = FeatureClassifier (FeatureVector -> ErrorFuncClass)
                -- ^ Use a classifier over feature vectors (possibly machine
                -- learning based) to classify error reporting functions
                | DefaultClassifier
                -- ^ Use a basic heuristic instead
                | NoClassifier
                -- ^ Do not attempt to learn error-reporting functions

data ErrorAnalysisOptions =
  ErrorAnalysisOptions { errorClassifier :: Classifier
                       , generalizeFromReturns :: Bool
                       }

defaultErrorAnalysisOptions :: ErrorAnalysisOptions
defaultErrorAnalysisOptions =
  ErrorAnalysisOptions { errorClassifier = DefaultClassifier
                       , generalizeFromReturns = True
                       }

identifyErrorHandling :: (HasFunction funcLike, HasBlockReturns funcLike,
                          HasCFG funcLike, HasCDG funcLike, HasDomTree funcLike)
                         => [funcLike]
                         -> DependencySummary
                         -> IndirectCallSummary
                         -> ErrorAnalysisOptions
                         -> ErrorSummary
identifyErrorHandling funcLikes ds ics opts =
  runAnalysis (fixAnalysis mempty) ds roData mempty
  where
    roData = ErrorData ics
    fixAnalysis res0 = do
      -- First, find known success blocks and known failure blocks
      res1 <- extractBasicFacts res0 funcLikes

      -- If we have a classifier, try it.  Otherwise, use a basic
      -- heuristic.  Use the classification to generalize and find
      -- new error blocks.
      st <- analysisGet
      let successCodes = mconcat (HM.elems (successModel st))
          base = res1 ^. errorBasicFacts
          errorFuncs = case errorClassifier opts of
            DefaultClassifier -> errorFuncHeuristic base funcLikes
            FeatureClassifier c -> classifyErrorFunctions base funcLikes c
            NoClassifier -> mempty
          ganalysis = generalizeBlockFromErrFunc errorFuncs successCodes base
      -- Generalizing based on error functions will learn new error values.
      res2 <- foldM (byBlock ganalysis) res1 funcLikes

      -- Now try to generalize based on error values
      res3 <- foldM (byBlock generalizeFromErrorCodes) res2 funcLikes

      -- Once we know all of the error blocks we can find in this pass,
      -- look for all of the transitive errors.  These don't give us any
      -- information that would help in other phases.
      res4 <- foldM (byBlock returnsTransitiveError) res3 funcLikes

      if res0 == res4 then return res0
        else fixAnalysis res4

-- | If a block returns an integer value in
generalizeFromErrorCodes :: (HasFunction funcLike, HasBlockReturns funcLike)
                         => funcLike
                         -> ErrorSummary
                         -> BasicBlock
                         -> Analysis ErrorSummary
generalizeFromErrorCodes = undefined


isUnclassifiedBlock :: BasicFacts -> BasicBlock -> Bool
isUnclassifiedBlock baseFacts bb = not $ M.member bb baseFacts

-- | This just needs to take the set of values and try to find new
-- error codes by generalizing.  Be careful to ignore blocks we
-- already know are reporting errors or successes.
--
-- We can also generalize based on return values (returning a constant known
-- to be an error code is highly suspicious).
--
-- | If the block has a constant return (not a success code) and calls an errFunc...
--
-- TODO: Incorporate information about finalizers.  Do not call a finalizer
-- an error reporting function (ever)
generalizeBlockFromErrFunc :: (HasFunction funcLike, HasBlockReturns funcLike)
                           => Set Value
                           -> Set Int
                           -> BasicFacts
                           -> funcLike
                           -> ErrorSummary
                           -> BasicBlock
                           -> Analysis ErrorSummary
generalizeBlockFromErrFunc errFuncs succCodes baseFacts funcLike summ bb
  | Just rv <- blockReturn brs bb
  , Just rc <- retValToConstantInt rv
  , Just errDesc <- blockErrorDescriptor rc
  , isUnclassifiedBlock baseFacts bb && not (S.member rc succCodes) =
    let val = S.singleton errDesc
    in return $ summ & errorSummary %~ HM.insertWith S.union f val
  | otherwise = return summ
  where
    brs = getBlockReturns funcLike
    f = basicBlockFunction bb
    isErrFuncCall i =
      case i of
        CallInst { callFunction = (stripBitcasts -> cv) }
          | S.member cv errFuncs -> fmap identifierAsString (valueName cv)
          | otherwise -> Nothing
        _ -> Nothing
    blockErrorDescriptor rc =
      let calledErrFuncs = mapMaybe isErrFuncCall (basicBlockInstructions bb)
          acts = map (\callee -> FunctionCall callee mempty) calledErrFuncs
          ret = ReturnConstantInt (S.singleton rc)
      in case null calledErrFuncs of
        True -> fail "Not an error block"
        False -> return $ ErrorDescriptor (S.fromList acts) ret []

-- | This is a basic heuristic to categorize functions as error-reporting
-- functions or not.  This is the fallback if no SVM classifier is
-- provided.
errorFuncHeuristic :: (HasFunction funcLike)
                   => BasicFacts
                   -> [funcLike]
                   -> Set Value
errorFuncHeuristic = undefined

extractBasicFacts :: (HasFunction funcLike, HasBlockReturns funcLike,
                      HasCFG funcLike, HasCDG funcLike, HasDomTree funcLike)
                  => ErrorSummary -> [funcLike] -> Analysis ErrorSummary
extractBasicFacts s0 funcLikes = do
  s1 <- foldM (byBlock reportsSuccess) s0 funcLikes
  foldM (byBlock handlesKnownError) s1 funcLikes

-- | Apply an analysis function to each 'BasicBlock' in a 'Function'.
--
-- The main analysis functions in this module all have the same signature
-- and are analyzed in this same way.
byBlock :: (HasFunction funcLike)
        => (funcLike -> ErrorSummary -> BasicBlock -> Analysis ErrorSummary)
        -> ErrorSummary
        -> funcLike
        -> Analysis ErrorSummary
byBlock analysis s funcLike =
  foldM (analysis funcLike) s (functionBody f)
  where
    f = getFunction funcLike

-- errorSummaryToString = unlines . map entryToString . HM.toList
--   where
--     entryToString (f, descs) = identifierAsString (functionName f) ++ ": " ++ show descs

instance SummarizeModule ErrorSummary where
  summarizeArgument _ _ = []
  summarizeFunction f (ErrorSummary summ _ _) = fromMaybe [] $ do
    fsumm <- HM.lookup f summ
    descs <- NEL.nonEmpty (F.toList fsumm)
    let retcodes = unifyReturnCodes descs
        ws = concatMap errorWitnesses (NEL.toList descs)
    case unifyErrorActions descs of
      Nothing -> return [(FAReportsErrors mempty retcodes, ws)]
      Just uacts -> return [(FAReportsErrors uacts retcodes, ws)]

-- | FIXME: Prefer error actions of size one (should discard extraneous
-- actions like cleanup code).
unifyErrorActions :: NonEmpty ErrorDescriptor -> Maybe (Set ErrorAction)
unifyErrorActions d0 = foldr unifyActions (Just d) ds
  where
    (d:|ds) = fmap errorActions d0
    unifyActions _ Nothing = Nothing
    unifyActions s1 acc@(Just s2)
      | S.size s1 == 1 && S.size s2 /= 1 = Just s1
      | s1 == s2 = acc
      | otherwise = Nothing

-- | Merge all return values; if ints and ptrs are mixed, prefer the
-- ints
unifyReturnCodes :: NonEmpty ErrorDescriptor -> ErrorReturn
unifyReturnCodes = F.foldr1 unifyReturns . fmap errorReturns
  where
    unifyReturns (ReturnConstantInt is1) (ReturnConstantInt is2) =
      ReturnConstantInt (is1 `S.union` is2)
    unifyReturns (ReturnConstantPtr is1) (ReturnConstantPtr is2) =
      ReturnConstantPtr (is1 `S.union` is2)
    unifyReturns (ReturnConstantPtr _) r@(ReturnConstantInt _) = r
    unifyReturns r@(ReturnConstantInt _) (ReturnConstantPtr _) = r

{-

1) Find all basic error reporting code that we /know/ handles errors.

2) Try to learn all at once, but also taking into account how often
   candidate error functions are called in non-error code.
   We could distinguish by looking at what is returned when the
   function is called (if it is not a constant, it is probably a mark
   against).

3) Try to generalize.

A problem with the current code is that we try to learn error functions
in isolation, which makes it very difficult to distinguish between
cleanup code and error reporting code.

Cleanup code will occur (much?) more often in contexts that do not have
a constant return value.

-}


-- | If the function transitively returns errors, record them in the
-- error summary.  Errors are only transitive if they are unhandled in
-- this function.  For example, consider the following code:
--
-- > bs = read(..);
-- > if(bs < 0) {
-- >   setError(..);
-- >   return -20;
-- > }
-- >
-- > return bs;
--
-- Here, we do /not/ want to say that this function returns a
-- transitive error, even though the result of @read@ is one of its
-- return values.  The error code (bs == -1) is handled in the
-- conditional, so only non-error values can be returned (except where
-- the error was converted into an application-specific error code).
--
-- This decision is made with a call to the theorem prover, taking in
-- to account all of the conditions that currently hold when the value
-- must be returned.  See the 'relevantInducedFacts' function for
-- details.
returnsTransitiveError :: (HasFunction funcLike, HasBlockReturns funcLike,
                           HasCFG funcLike, HasCDG funcLike, HasDomTree funcLike)
                       => funcLike
                       -> ErrorSummary
                       -> BasicBlock
                       -> Analysis ErrorSummary
returnsTransitiveError funcLike summ bb
  | Just rv <- blockReturn brs bb = do
    ics <- analysisEnvironment indirectCallSummary
    case ignoreCasts rv of
      InstructionC i@CallInst { callFunction = callee } -> do
        let callees = callTargets ics callee
        priorFacts <- relevantInducedFacts funcLike bb i
        foldM (recordTransitiveError i priorFacts) summ callees
      _ -> return summ
  | otherwise = return summ
  where
    f = getFunction funcLike
    brs = getBlockReturns funcLike
    recordTransitiveError i priors s callee = do
      let w = Witness i "transitive error"
      fsumm <- lookupFunctionSummaryList s callee
      maybe (return s) (addErrorDescriptor f s) $ do
        FAReportsErrors errActs eret <- F.find isErrRetAnnot fsumm
        rvs <- intReturnsToList eret
        -- See Note [Transitive Returns with Conditions]
        case priors of
          Nothing -> return $! ErrorDescriptor errActs eret [w]
          Just priors' -> do
            let rvs' = foldr (addUncaughtErrors priors') mempty rvs
            return $! ErrorDescriptor errActs (ReturnConstantInt rvs') [w]

-- | Update the error summary with the given descriptor.  If the
-- descriptor is returning an integer error code, additionally
-- file that code away in the errorCodes state for later generalization.
addErrorDescriptor :: Function -> ErrorSummary -> ErrorDescriptor
                   -> Analysis ErrorSummary
addErrorDescriptor f s d
  | Just is <- intReturnsToList (errorReturns d) = do
    st <- analysisGet
    analysisPut st { errorCodes = S.fromList is `mappend` errorCodes st }
    return s'
  | otherwise = return s'
  where
    s' = s & errorSummary %~ HM.insertWith S.union f (S.singleton d)


-- | Check an error code @rc@ against all relevant conditions that are
-- active at the current program point.  If @rc@ has not been handled
-- by a different branch, add it to the list of error codes that could
-- be returned here.
--
-- Effectively, this filters out codes that are handled by other
-- branches and cannot be returned here.
addUncaughtErrors :: (SInt32 -> SBool) -> Int -> Set Int -> Set Int
addUncaughtErrors priors rc acc
  | isSat formula = S.insert rc acc
  | otherwise = acc
  where
    formula (x :: SInt32) = x .== fromIntegral rc &&& priors x

intReturnsToList :: ErrorReturn -> Maybe [Int]
intReturnsToList er =
  case er of
    ReturnConstantInt is -> return $ S.toList is
    _ -> Nothing


-- | In this case, the basic block is handling a known error and turning it
-- into an integer return code (possibly while performing some other
-- relevant error-reporting actions).
handlesKnownError :: (HasFunction funcLike, HasBlockReturns funcLike,
                      HasCFG funcLike, HasCDG funcLike, HasDomTree funcLike)
                  => funcLike
                  -> ErrorSummary
                  -> BasicBlock
                  -> Analysis ErrorSummary
handlesKnownError funcLike s bb -- See Note [Known Error Conditions]
  | Just rv <- blockReturn brs bb
  , Just _ <- retValToConstantInt rv = do
    let termInst = basicBlockTerminatorInstruction bb
        cdeps = controlDependencies funcLike termInst
    foldM (checkForKnownErrorReturn funcLike bb) s cdeps
  | otherwise = return s
  where
    brs = getBlockReturns funcLike

-- | For a given conditional branch (which is a control dependency of
-- a block returning the constant @iv@), determine whether or not the
-- condition is checking the return value of a function we know returns
-- error codes.  If it is, construct the formula that determines whether or
-- not we are on an error handling branch.
--
-- If we are, update the summary with this return value (@iv@) and any
-- error-reporting actions we see in this block.  TODO: We might be able to
-- make an argument that we should look back up multiple blocks from here
-- to the conditional check....
--
-- Note that we take the first (nearest) checked error we find.
--
-- As error descriptors are learned, this function records returned error
-- codes in the analysis state.  These will be used later to attempt
-- generalizations.
checkForKnownErrorReturn :: (HasFunction funcLike, HasCFG funcLike, HasDomTree funcLike,
                             HasCDG funcLike, HasBlockReturns funcLike)
                         => funcLike
                         -> BasicBlock
                         -- ^ The block returning the Int value
                         -> ErrorSummary
                         -> Instruction
                         -> Analysis ErrorSummary
checkForKnownErrorReturn funcLike bb s brInst = do
  res <- runMaybeT $ do
    (target, isErrHandlingFormula) <- targetOfErrorCheckBy s brInst
    ifacts <- lift $ relevantInducedFacts funcLike bb target
    ifacts' <- liftMaybe ifacts
    let formula (x :: SInt32) = isErrHandlingFormula x &&& ifacts' x
    case isSat formula of
      -- This block is not handling an error
      False -> fail "Not handling an error"
      -- This block is handling an error and returning a constant, so figure
      -- out what error handling actions it is taking and modify the summary.
      True -> do
        (errDesc, valsUsedAsArgs) <- branchToErrorDescriptor funcLike bb
        let w1 = Witness target "check error return"
            w2 = Witness brInst "return error code"
            d = errDesc { errorWitnesses = [w1, w2] }
        return (d, valsUsedAsArgs)
  case res of
    Nothing -> return s
    Just (d, argVals) -> do
      fitsSuccessModel <- checkFitsSuccessModelFor f d
      case fitsSuccessModel of
        False -> do
          let s' = s & errorBasicFacts %~ M.insert bb (ErrorBlock argVals)
          addErrorDescriptor f s' d
        True -> do
          let s' = s & errorBasicFacts %~ M.insert bb SuccessBlock
          removeImprobableErrors f s' d
  where
    f = getFunction funcLike

removeImprobableErrors :: Function -> ErrorSummary -> ErrorDescriptor
                       -> Analysis ErrorSummary
removeImprobableErrors f s (ErrorDescriptor _ (ReturnConstantInt dis) _) =
  return $ s & errorSummary %~ HM.adjust (S.foldr go mempty) f
  where
    go d@(ErrorDescriptor acts (ReturnConstantInt is) ws) acc
      | S.null (S.intersection is dis) = S.insert d acc -- no overlap
      | is == dis = acc -- identical, just remove
      | otherwise = -- Some overlap, need to remove offending codes
        let consts' = S.difference is dis
            desc = ErrorDescriptor acts (ReturnConstantInt consts') ws
        in S.insert desc acc
    go d acc = S.insert d acc
removeImprobableErrors _ s _ = return s

checkFitsSuccessModelFor :: Function -> ErrorDescriptor -> Analysis Bool
checkFitsSuccessModelFor f (ErrorDescriptor _ (ReturnConstantInt is) _) = do
  st <- analysisGet
  case HM.lookup f (successModel st) of
    Nothing -> return False
    Just m -> return $ not $ S.null (is `S.intersection` m)
checkFitsSuccessModelFor _ _ = return False

-- | Given a branch instruction, if the branch is checking the return value of
-- a function call, return the function call instruction and a formula that
-- describes when an error is being checked.
--
-- FIXME: This could handle switches based on return values
targetOfErrorCheckBy :: ErrorSummary -> Instruction
                     -> MaybeT Analysis (Instruction, SInt32 -> SBool)
targetOfErrorCheckBy s i = do
  ics <- lift $ analysisEnvironment indirectCallSummary
  case i of
    BranchInst { branchCondition = (valueContent' ->
      InstructionC ICmpInst { cmpV1 = v1, cmpV2 = v2 })} -> do
        (ci, callee) <- firstCallInst [v1, v2]
        let callees = callTargets ics callee
        rvs <- errorReturnValues s callees
        let formula (x :: SInt32) = bAny (.==x) (map fromIntegral rvs)
        return (ci, formula)
    _ -> fail "Not a conditional branch"

-- | The other analyses identify error handling code.  This one instead looks
-- for code that we can prove is /not/ handling an error.  If we are on a
-- branch that we know is not handling an error AND it always returns the same
-- constant integer value (on all paths), we will treat that value as a
-- /success code/.
--
-- We can use that value to prevent strange code from calling a function that
-- returns an error and checking for the result (but doing nothing about it).
-- In those cases, the fallthrough could make it look like the function
-- "handled" the error by returning "success".
--
-- Basically, we use positive information to isolate bad behavior.
--
-- See tests/error-handling/reused-error-reporter.c for an example where this
-- is critical.
reportsSuccess :: (HasFunction funcLike, HasBlockReturns funcLike,
                   HasCFG funcLike, HasCDG funcLike, HasDomTree funcLike)
               => funcLike
               -> ErrorSummary
               -> BasicBlock
               -> Analysis ErrorSummary
reportsSuccess funcLike s bb
  | Just spred <- singlePredecessor cfg bb
  , Just rv <- blockReturnsSameIntOnPaths rets = do
    res <- runMaybeT $ do
      let brInst = basicBlockTerminatorInstruction spred
      (target, isErrHandlingFormula) <- targetOfErrorCheckBy s brInst
      ifacts <- lift $ relevantInducedFacts funcLike bb target
      ifacts' <- liftMaybe ifacts
      let formula (x :: SInt32) = isErrHandlingFormula x &&& ifacts' x
      case isSat formula of
        True -> fail "Not a success branch"
        -- In this block, some call that can return errors did /not/ return an
        -- error.  We also know that the value @rv@ is /always/ returned from
        -- this point, so we will conclude that @rv@ is a success code.
        False -> do
          st <- lift analysisGet
          let model = successModel st
              model' = HM.insertWith S.union f (S.singleton rv) model
          lift $ analysisPut st { successModel = model' }
          return s
    return $ fromMaybe s res
  | otherwise = return s
  where
    f = getFunction funcLike
    brs = getBlockReturns funcLike
    cfg = getCFG funcLike
    rets = blockReturns brs bb

blockReturnsSameIntOnPaths :: [Value] -> Maybe Int
blockReturnsSameIntOnPaths [] = Nothing
blockReturnsSameIntOnPaths (v:vs)
  | all (==v) vs = retValToConstantInt v
  | otherwise = Nothing

-- | Return the first call instruction and its callee
firstCallInst :: [Value] -> MaybeT Analysis (Instruction, Value)
firstCallInst [] = fail "No call inst"
firstCallInst (v:vs) =
  case fromValue (ignoreCasts v) of
    Nothing -> firstCallInst vs
    Just i@CallInst { callFunction = callee } -> return (i, callee)
    _ -> firstCallInst vs


-- | Produce a formula representing all of the facts we must hold up
-- to this point.  The argument of the formula is the variable
-- representing the return value of the function we are interested in.
--
-- This is necessary to correctly handle conditions that are checked
-- in multiple parts (or just compound conditions).  Note that the
-- approach here is not quite complete - if part of a compound
-- condition is checked far away and we can't prove that it still
-- holds, we will miss it.  It should cover the realistic cases,
-- though.
--
-- As an example, consider:
--
-- > bytesRead = read(...);
-- > if(bytesRead < 0) {
-- >   signalError(...);
-- >   return ERROR;
-- > }
-- >
-- > if(bytesRead == 0) {
-- >   return EOF;
-- > }
-- >
-- > return OK;
--
-- Checking the first clause in isolation correctly identifies
-- signalError as an error function and ERROR as an error return code.
-- However, checking the second in isolation implies that OK is an
-- error code.
--
-- The correct thing to do is to check the second condition with the
-- fact @bytesRead >= 0@ in scope, which gives the compound predicate
--
-- > bytesRead >= 0 &&& bytesRead /= 0 &&& bytesRead == -1
--
-- or
--
-- > bytesRead >= 0 &&& bytesRead == 0 &&& bytesRead == -1
--
-- Both of these are unsat, which is what we want (since the second
-- condition isn't checking an error).
relevantInducedFacts :: (HasFunction funcLike, HasBlockReturns funcLike,
                         HasCFG funcLike, HasCDG funcLike, HasDomTree funcLike)
                     => funcLike
                     -> BasicBlock
                     -> Instruction
                     -> Analysis (Maybe (SInt32 -> SBool))
relevantInducedFacts funcLike bb0 target = do
  st <- analysisGet
  case HM.lookup (f, bb0, target) (formulaCache st) of
    Just formula -> return formula
    Nothing -> do
      let formula = evalState (computeInducedFacts funcLike bb0 target) (mempty, mempty)
      analysisPut st { formulaCache = HM.insert (f, bb0, target) formula (formulaCache st) }
      return formula
  where
    f = getFunction funcLike

type FormulaBuilder = State (Set Instruction, HashMap (BasicBlock, Instruction) (Maybe (SInt32 -> SBool)))

computeInducedFacts :: (HasFunction funcLike, HasBlockReturns funcLike,
                        HasCFG funcLike, HasCDG funcLike, HasDomTree funcLike)
                    => funcLike
                    -> BasicBlock
                    -> Instruction
                    -> FormulaBuilder (Maybe (SInt32 -> SBool))
computeInducedFacts funcLike bb0 target
  | S.null cdeps = return Nothing
  | otherwise = buildRelevantFacts bb0
  where
    ti0 = basicBlockTerminatorInstruction bb0
    cdeps = S.fromList $ controlDependencies funcLike ti0
    buildRelevantFacts bb
      | otherwise =
        let ti = basicBlockTerminatorInstruction bb
            dirCdeps = directControlDependencies funcLike ti
        in case dirCdeps of
          [] -> return Nothing
          [singleDep] -> memoBuilder bb singleDep
          _ -> do
            fs <- mapM (memoBuilder bb) dirCdeps
            case catMaybes fs of
              [] -> return Nothing
              fs' -> return $ Just $ \(x :: SInt32) -> bAny ($ x) fs'

    memoBuilder :: BasicBlock -> Instruction
                -> FormulaBuilder (Maybe (SInt32 -> SBool))
    memoBuilder bb cdep = do
      (visited, s) <- get
      case HM.lookup (bb, cdep) s of
        Just f -> return f
        Nothing ->
          case S.member cdep visited of
            True -> return Nothing
            False -> do
              put (S.insert cdep visited, s)
              factBuilder bb cdep
    factBuilder :: BasicBlock -> Instruction
                -> FormulaBuilder (Maybe (SInt32 -> SBool))
    factBuilder bb cdep = do
      let Just cdepBlock = instructionBasicBlock cdep
      case cdep of
        BranchInst { branchTrueTarget = tt
                   , branchCondition = (valueContent' ->
          InstructionC ICmpInst { cmpPredicate = p
                                , cmpV1 = val1
                                , cmpV2 = val2
                                })}
            | ignoreCasts val1 == toValue target ||
              ignoreCasts val2 == toValue target -> do
                let doNeg = if blockDominates funcLike tt bb then id else bnot
                    thisFact = inducedFact val1 val2 p doNeg
                innerFact <- buildRelevantFacts cdepBlock
                let fact' = liftedConjoin thisFact innerFact
                (vis, st) <- get
                put $ (vis, HM.insert (bb, cdep) fact' st)
                return fact'
            | otherwise -> buildRelevantFacts cdepBlock
        _ -> return Nothing


liftedConjoin :: Maybe (SInt32 -> SBool) -> Maybe (SInt32 -> SBool)
              -> Maybe (SInt32 -> SBool)
liftedConjoin Nothing Nothing = Nothing
liftedConjoin f1@(Just _) Nothing = f1
liftedConjoin Nothing f2@(Just _) = f2
liftedConjoin (Just f1) (Just f2) = Just $ \(x :: SInt32) -> f1 x &&& f2 x

blockDominates :: (HasDomTree t) => t -> BasicBlock -> BasicBlock -> Bool
blockDominates f b1 b2 = dominates f i1 i2
  where
    i1 = basicBlockTerminatorInstruction b1
    i2 = basicBlockTerminatorInstruction b2

-- | Given a formula that holds up to the current location @mf@, augment
-- it by conjoining the new fact we are introducing (if any).  The new
-- fact is derived from the relationship ('CmpPredicate') between the two
-- 'Value' arguments.
inducedFact :: Value -> Value -> CmpPredicate
            -> (SBool -> SBool) -> Maybe (SInt32 -> SBool)
inducedFact val1 val2 p doNeg = do
  rel <- cmpPredicateToRelation p
  case (valueContent' val1, valueContent' val2) of
    (ConstantC ConstantInt { constantIntValue = (fromIntegral -> iv) }, _) ->
      return $ \(x :: SInt32) -> doNeg (iv `rel` x)
    (_, ConstantC ConstantInt { constantIntValue = (fromIntegral -> iv)}) ->
      return $ \(x :: SInt32) -> doNeg (x `rel` iv)
    (ConstantC ConstantPointerNull {}, _) ->
      return $ \(x :: SInt32) -> doNeg (0 `rel` x)
    (_, ConstantC ConstantPointerNull {}) ->
      return $ \(x :: SInt32) -> doNeg (x `rel` 0)
    -- Not a comparison against a constant int, so we didn't learn anything.
    -- This is different from failure - we still had whatever information we
    -- had from before.
    _ -> fail "Cannot produce a fact here"

cmpPredicateToRelation :: CmpPredicate -> Maybe (SInt32 -> SInt32 -> SBool)
cmpPredicateToRelation p =
  case p of
    ICmpEq -> return (.==)
    ICmpNe -> return (./=)
    ICmpUgt -> return (.>)
    ICmpUge -> return (.>=)
    ICmpUlt -> return (.<)
    ICmpUle -> return (.<=)
    ICmpSgt -> return (.>)
    ICmpSge -> return (.>=)
    ICmpSlt -> return (.<)
    ICmpSle -> return (.<=)
    _ -> fail "cmpPredicateToRelation is a floating point comparison"

isSat :: (SInt32 -> SBool) -> Bool
isSat f = unsafePerformIO $ do
  Just sr <- isSatisfiable Nothing f
  return sr

errorReturnValues :: ErrorSummary -> [Value] -> MaybeT Analysis [Int]
errorReturnValues _ [] = fail "No call targets"
errorReturnValues s [callee] = do
  fsumm <- lift $ lookupFunctionSummaryList s callee
  liftMaybe $ errRetVals fsumm
errorReturnValues s (callee:rest) = do
  fsumm <- lift $ lookupFunctionSummaryList s callee
  rvs <- liftMaybe $ errRetVals fsumm
  -- This lets us emit a warning if some callees return errors while
  -- others do not
  mapM_ (checkOtherErrorReturns rvs) rest
  return rvs
  where
    checkOtherErrorReturns rvs c = do
      fsumm <- lift $ lookupFunctionSummaryList s c
      rvs' <- liftMaybe $ errRetVals fsumm
      let inter = S.intersection (S.fromList rvs') (S.fromList rvs)
      when (S.null inter) $ emitWarning Nothing "ErrorAnalysis" ("Mismatched error return codes for indirect call " ++ show (valueName callee))

errRetVals :: [FuncAnnotation] -> Maybe [Int]
errRetVals [] = Nothing
errRetVals (FAReportsErrors _ ract : _) = do
  case ract of
    ReturnConstantInt is ->
      case F.toList is of
        [] -> Nothing
        lis -> return lis
    ReturnConstantPtr is ->
      case F.toList is of
        [] -> Nothing
        lis -> return lis
errRetVals (_:rest) = errRetVals rest

callTargets :: IndirectCallSummary -> Value -> [Value]
callTargets ics callee =
  case valueContent' callee of
    FunctionC _ -> [callee]
    ExternalFunctionC _ -> [callee]
    _ -> indirectCallInitializers ics callee

isErrRetAnnot :: FuncAnnotation -> Bool
isErrRetAnnot (FAReportsErrors _ _) = True
isErrRetAnnot _ = False

branchToErrorDescriptor :: (HasFunction funcLike, HasBlockReturns funcLike,
                            HasCFG funcLike, HasCDG funcLike)
                        => funcLike -> BasicBlock
                        -> MaybeT Analysis (ErrorDescriptor, Set Value)
branchToErrorDescriptor funcLike bb = do
  singleRetVal <- liftMaybe $ blockReturn brs bb
  constantRc <- liftMaybe $ retValToConstantInt singleRetVal
  let rcon = if functionReturnsPointer f
             then ReturnConstantPtr
             else ReturnConstantInt
      ract = rcon (S.singleton constantRc)
      (acts, ignored) = foldr instToAction ([], mempty) (basicBlockInstructions bb)
  return $! (ErrorDescriptor (S.fromList acts) ract [], ignored)
  where
    f = getFunction funcLike
    brs = getBlockReturns funcLike

retValToConstantInt :: Value -> Maybe Int
retValToConstantInt v = do
  ConstantInt { constantIntValue = (fromIntegral -> iv) } <- fromValue v
  return iv

functionReturnsPointer :: Function -> Bool
functionReturnsPointer f =
  case functionReturnType f of
    TypePointer _ _ -> True
    _ -> False

-- | The set of values tracked alongside the accumulator are the values used
-- as arguments to function calls.  Due to the right-association of foldr,
-- this effectively works backwards and lets us ignore function calls used as
-- arguments to other functions.
--
-- We will want this set to use while defining features.
instToAction ::Instruction -> ([ErrorAction], Set Value) -> ([ErrorAction], Set Value)
instToAction i a@(acc, ignore) =
  case i of
    CallInst { callFunction = (valueContent' -> FunctionC f)
             , callArguments = (map fst -> args)
             }
      | toValue i `S.member` ignore ->
        (acc, foldr S.insert ignore args)
      | otherwise ->
        let fname = identifierAsString (functionName f)
            argActs = foldr callArgActions mempty (zip [0..] args)
        in (FunctionCall fname argActs : acc, foldr S.insert ignore args)
    _ -> a

callArgActions :: (Int, Value)
                  -> IntMap ErrorActionArgument
                  -> IntMap ErrorActionArgument
callArgActions (ix, v) acc =
  case valueContent' v of
    ArgumentC a ->
      let atype = show (argumentType a)
          aix = argumentIndex a
      in IM.insert ix (ErrorArgument atype aix) acc
    ConstantC ConstantInt { constantIntValue = (fromIntegral -> iv) } ->
      IM.insert ix (ErrorInt iv) acc
    _ -> acc

singlePredecessor :: CFG -> BasicBlock -> Maybe BasicBlock
singlePredecessor cfg bb =
  case basicBlockPredecessors cfg bb of
    [singlePred] -> return singlePred
    _ -> Nothing

liftMaybe :: Maybe a -> MaybeT Analysis a
liftMaybe = maybe mzero return

ignoreCasts :: Value -> Value
ignoreCasts v =
  case valueContent v of
    InstructionC BitcastInst { castedValue = cv } -> ignoreCasts cv
    InstructionC TruncInst { castedValue = cv } -> ignoreCasts cv
    InstructionC ZExtInst { castedValue = cv } -> ignoreCasts cv
    InstructionC SExtInst { castedValue = cv } -> ignoreCasts cv
    InstructionC IntToPtrInst { castedValue = cv } -> ignoreCasts cv
    GlobalAliasC GlobalAlias { globalAliasTarget = t } -> ignoreCasts t
    ConstantC ConstantValue { constantInstruction = BitcastInst { castedValue = cv } } -> ignoreCasts cv
    _ -> valueContent v

{- Note [Known Error Conditions]

We look for code handling known error conditions starting from basic blocks
that return a constant int value.  Blocks with more than one predecessor
are handled by constructing a separate formula for each predecessor.  The
formulas are disjuncts that are ORed together.  This composite formula is then
checked with the "target error" formula (via AND).

This means that we are checking to see if an error MAY be checked from a given
block, but that is actually sufficient for our purposes.  It still means that
there is a path where an error is checked and then a constant integer is
returned.

An older version of the code stopped when it found an error being handled
(taking the first control dependency).  Now it just inspects them all.  This
should not really cause a problem.  It might introduce a little redundancy, but
the results should always be the same.  The function @checkForKnownErrorReturn@
could be modified to go back to the old behavior.

-}

{- Note [Transitive Returns with Conditions]

This note affects transitive error returns:

> rc = errorReturningFunction();
> ...
> return rc;

In the most basic scenario (if there are no conditions affecting the
return), the transitive return case is simple: the caller just returns
all of the same return codes as the callee.

If the return statement is guarded by conditions, though, this is not
so simple:

> rc = errorReturningFunction();
> if(rc == WARN) return FATAL;
> return rc;

Here, the function hosting this code cannot (at this call site) return
WARN as an error code because that is intercepted earlier and
converted to FATAL.  Thus, passing all of the return codes of
errorReturningFunction() to the caller is too much of an
overapproximation, and an avoidable one.

To deal with this, we check EACH return code from
errorReturningFunction() against the conditions in scope at this
return statement.  Assume the callee can return WARN and FATAL.

 * rc == FATAL && rc /= WARN

   This is satisfiable (assuming FATAL and WARN have different integer
   values, which they would in any real setting).  Thus, this caller can
   return FATAL.

 * rc == WARN && rc /= WARN

   This is unsatisfiable no matter how you look at it, so this return
   statement *cannot* return WARN.

The function 'addUncaughtErrors' is in charge of generating the
relevant formulas (based on the results of the general function that
collects all of the "in scope" conditions).

See test case error-handling/filters-error-codes-with-branch.c for a
full example of this issue.

The special handling of the @null priors@ case is not really necessary,
but it saves a potentially large number of pointless theorem prover calls.

-}
