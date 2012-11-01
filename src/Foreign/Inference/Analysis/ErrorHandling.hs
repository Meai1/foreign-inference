{-# LANGUAGE ViewPatterns, RankNTypes, ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric #-}
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
  identifyErrorHandling,
  ) where

import GHC.Generics

import Control.DeepSeq
import Control.DeepSeq.Generics ( genericRnf )
import Control.Monad ( foldM, when )
import Control.Monad.Trans.Class
import Control.Monad.Trans.Maybe
import qualified Data.Foldable as F
import Data.HashMap.Strict ( HashMap )
import qualified Data.HashMap.Strict as HM
import Data.IntMap ( IntMap )
import qualified Data.IntMap as IM
import Data.List ( elemIndex )
import Data.List.NonEmpty ( NonEmpty(..) )
import qualified Data.List.NonEmpty as NEL
import Data.Maybe ( fromMaybe )
import Data.Monoid
import Data.SBV
import Data.Set ( Set )
import qualified Data.Set as S
import System.IO.Unsafe ( unsafePerformIO )

import LLVM.Analysis
import LLVM.Analysis.BlockReturnValue
import LLVM.Analysis.CDG
import LLVM.Analysis.CFG

import Foreign.Inference.AnalysisMonad
import Foreign.Inference.Diagnostics
import Foreign.Inference.Interface
import Foreign.Inference.Internal.FlattenValue
import Foreign.Inference.Analysis.IndirectCallResolver

-- import Text.Printf
import Debug.Trace
debug :: a -> String -> a
debug = flip trace

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
type SummaryType = HashMap Function (Set ErrorDescriptor)
data ErrorSummary = ErrorSummary SummaryType Diagnostics
                  deriving (Generic)

instance Eq ErrorSummary where
  (ErrorSummary s1 _) == (ErrorSummary s2 _) = s1 == s2

instance Monoid ErrorSummary where
  mempty = ErrorSummary mempty mempty
  mappend (ErrorSummary m1 d1) (ErrorSummary m2 d2) =
    ErrorSummary (HM.union m1 m2) (mappend d1 d2)

instance NFData ErrorSummary where
  rnf = genericRnf

-- This is a manual lens implementation as described in the lens
-- package.
instance HasDiagnostics ErrorSummary where
  diagnosticLens f (ErrorSummary s d) =
    fmap (\d' -> ErrorSummary s d') (f d)

data ErrorData =
  ErrorData { dependencySummary :: DependencySummary
            , indirectCallSummary :: IndirectCallSummary
            }

-- | This is the data we want to bootstrap through the two
-- generalization rules
data ErrorState =
  ErrorState { errorCodes :: Set Int
             , errorFunctions :: Set String
             }

instance Monoid ErrorState where
  mempty = ErrorState mempty mempty
  mappend (ErrorState c1 f1) (ErrorState c2 f2) =
    ErrorState (c1 `mappend` c2) (f1 `mappend` f2)


type Analysis = AnalysisMonad ErrorData ErrorState

identifyErrorHandling :: (HasFunction funcLike, HasBlockReturns funcLike,
                          HasCFG funcLike, HasCDG funcLike)
                         => [funcLike]
                         -> DependencySummary
                         -> IndirectCallSummary
                         -> ErrorSummary
identifyErrorHandling funcLikes ds ics =
  runAnalysis analysis roData mempty
  where
    roData = ErrorData ds ics
    analysis = do
      res <- fixAnalysis mempty
      -- The diagnostics will be filled in automatically by runAnalysis
--      return () `debug` errorSummaryToString res
      return $ ErrorSummary res mempty
    fixAnalysis res = do
      res' <- foldM errorAnalysis res funcLikes
      if res == res' then return res
        else fixAnalysis res'

-- errorSummaryToString = unlines . map entryToString . HM.toList
--   where
--     entryToString (f, descs) = identifierAsString (functionName f) ++ ": " ++ show descs

instance SummarizeModule ErrorSummary where
  summarizeArgument _ _ = []
  summarizeFunction f (ErrorSummary summ _) = fromMaybe [] $ do
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


errorAnalysis :: (HasFunction funcLike, HasBlockReturns funcLike,
                  HasCFG funcLike, HasCDG funcLike)
                 => SummaryType -> funcLike -> Analysis SummaryType
errorAnalysis summ funcLike = do
  summ' <- returnsTransitiveError f summ
  foldM (errorsForBlock funcLike) summ' (functionBody f)
  where
    f = getFunction funcLike

-- | Find the error handling code in this block
errorsForBlock :: (HasFunction funcLike, HasBlockReturns funcLike,
                   HasCFG funcLike, HasCDG funcLike)
                  => funcLike
                  -> SummaryType
                  -> BasicBlock
                  -> Analysis SummaryType
errorsForBlock funcLike s bb = do
  takeFirst s [ handlesKnownError funcLike s bb
              , matchActionAndGeneralizeReturn funcLike s bb
              ]
  where
    takeFirst :: (Monad m) => a -> [m (Maybe a)] -> m a
    takeFirst def [] = return def
    takeFirst def (act:rest) = do
      res <- act
      maybe (takeFirst def rest) return res

-- | If the function transitively returns errors, record them
-- in the error summary
returnsTransitiveError :: Function -> SummaryType -> Analysis SummaryType
returnsTransitiveError f summ = do
  ds <- analysisEnvironment dependencySummary
  ics <- analysisEnvironment indirectCallSummary
  return $ fromMaybe summ $ do
    exitInst <- functionExitInstruction f
    case exitInst of
      RetInst { retInstValue = Just rv } ->
        let rvs = flattenValue rv
        in return $ foldr (checkTransitiveError ics ds) summ rvs
      _ -> return summ
  where
    checkTransitiveError :: IndirectCallSummary
                            -> DependencySummary
                            -> Value
                            -> SummaryType
                            -> SummaryType
    checkTransitiveError ics ds rv s =
      case valueContent' rv of
        InstructionC i@CallInst { callFunction = callee } ->
          let callees = callTargets ics callee
          in foldr (recordTransitiveError ds i) s callees
        _ -> s

    recordTransitiveError :: DependencySummary -> Instruction
                             -> Value -> SummaryType
                             -> SummaryType
    recordTransitiveError ds i callee s = fromMaybe s $ do
      fsumm <- lookupFunctionSummary ds (ErrorSummary s mempty) callee
      FAReportsErrors errActs eret <- F.find isErrRetAnnot fsumm
      let w = Witness i "transitive error"
          d = ErrorDescriptor errActs eret [w]
      return $ HM.insertWith S.union f (S.singleton d) s

-- | Try to generalize (learn new error codes) based on known error
-- functions that are called in this block.  If the block calls a
-- known error function and then returns a constant int, that is a new
-- error code.
matchActionAndGeneralizeReturn :: (HasFunction funcLike, HasBlockReturns funcLike,
                                   HasCFG funcLike, HasCDG funcLike)
                                  => funcLike
                                  -> SummaryType
                                  -> BasicBlock
                                  -> Analysis (Maybe SummaryType)
matchActionAndGeneralizeReturn funcLike s bb =
  -- If this basic block calls any functions in the errFuncs set, then
  -- use branchToErrorDescriptor f bb to compute a new error
  -- descriptor and then add the return value to the errCodes set.
  runMaybeT $ do
    let f = getFunction funcLike
        brets = getBlockReturns funcLike
    edesc <- branchToErrorDescriptor f brets bb
    st <- lift $ analysisGet
    let fs = errorFunctions st
    FunctionCall ecall _ <- liftMaybe $ F.find (isErrorFuncCall fs) (errorActions edesc)
    case errorReturns edesc of
      ReturnConstantPtr _ -> fail "Ptr return"
      ReturnConstantInt is -> do
        let ti = basicBlockTerminatorInstruction bb
            w = Witness ti ("Called " ++ ecall)
            d = edesc { errorWitnesses = [w] }
        lift $ analysisPut st { errorCodes = errorCodes st `S.union` is }
        return $! HM.insertWith S.union f (S.singleton d) s

-- | If the function handles an error from a callee that we already
-- know about, this will tell us what this caller does in response.
handlesKnownError :: (HasFunction funcLike, HasBlockReturns funcLike,
                      HasCFG funcLike, HasCDG funcLike)
                     => funcLike
                     -> SummaryType
                     -> BasicBlock
                     -> Analysis (Maybe SummaryType)
handlesKnownError funcLike s bb =
  case basicBlockTerminatorInstruction bb of
    bi@BranchInst { branchCondition = (valueContent' ->
      InstructionC ci@ICmpInst { cmpPredicate = p
                               , cmpV1 = v1
                               , cmpV2 = v2
                               })
               , branchTrueTarget = tt
               , branchFalseTarget = ft
               } -> runMaybeT $ do
      let f = getFunction funcLike
          inducedFacts = relevantInducedFacts funcLike ci v1 v2
          brets = getBlockReturns funcLike
      errDesc <- extractErrorHandlingCode f brets inducedFacts s p v1 v2 tt ft
      let acts = errorActions errDesc
      -- Only add a function to the errorFunctions set if the error
      -- action consists of *only* a single function call.  This is a
      -- heuristic to filter out actions that contain cleanup code
      -- that we would like to ignore (e.g., fclose, which is not an
      -- error reporting function).
      when (S.size acts == 1) $ do
        st <- analysisGet
        case F.find isFuncallAct acts of
          Just (FunctionCall fname _) ->
            analysisPut st { errorFunctions = S.insert fname (errorFunctions st) }
          _ -> return ()
      let w1 = Witness ci "check error return"
          w2 = Witness bi "return error code"
          d = errDesc { errorWitnesses = [w1, w2] }
      return $! HM.insertWith S.union f (S.singleton d) s
    _ -> return Nothing

-- | Produce a formula representing all of the facts we must hold up
-- to this point.  The argument of the formula is the variable
-- representing the return value of the function we are interested in
-- (and is one of the two values passed in).
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
                         HasCFG funcLike, HasCDG funcLike)
                        => funcLike
                        -> Instruction
                        -> Value
                        -> Value
                        -> (SInt32 -> SBool)
relevantInducedFacts funcLike i v1 v2 =
  let identFormula = const true
      Just bb = instructionBasicBlock i
  in case (valueContent' v1, valueContent' v2) of
    (InstructionC CallInst {}, _) ->
      buildRelevantFacts v1 bb identFormula
    (_, InstructionC CallInst {}) ->
      buildRelevantFacts v2 bb identFormula
    _ -> identFormula
  where
    cfg = getCFG funcLike
    cdg = getCDG funcLike
    -- These are all conditional branch instructions
    cdeps = S.fromList $ controlDependencies cdg i
    -- | Given that we are currently at @bb@, figure out how we got
    -- here (and what condition must hold for that to be the case).
    -- Do this by walking back in the CFG along unconditional edges
    -- and stopping when we hit a block terminated by a branch in
    -- @cdeps@ (a control-dependent branch).
    --
    -- If we ever reach a point where we have two predecessors, give
    -- up since we don't know any more facts for sure.
    buildRelevantFacts target bb acc
      | S.null cdeps = acc
      | otherwise = fromMaybe acc $ do
        singlePred <- singlePredecessor cfg bb
        let br = basicBlockTerminatorInstruction singlePred
        case br of
          UnconditionalBranchInst {} ->
            return $ buildRelevantFacts target singlePred acc
          bi@BranchInst { branchTrueTarget = tt
                     , branchCondition = (valueContent' ->
            InstructionC ICmpInst { cmpPredicate = p
                                  , cmpV1 = val1
                                  , cmpV2 = val2
                                  })}
            | not (S.member bi cdeps) -> Nothing
            | val1 == target || val2 == target ->
              let doNeg = if bb == tt then id else bnot
                  fact' = augmentFact acc val1 val2 p doNeg
              in return $ buildRelevantFacts target singlePred fact'
            | otherwise -> return $ buildRelevantFacts target singlePred acc
          _ -> Nothing

augmentFact :: (SInt32 -> SBool) -> Value -> Value -> CmpPredicate
               -> (SBool -> SBool) -> (SInt32 -> SBool)
augmentFact fact val1 val2 p doNeg = fromMaybe fact $ do
  (rel, _) <- cmpPredicateToRelation p
  case (valueContent' val1, valueContent' val2) of
    (ConstantC ConstantInt { constantIntValue = (fromIntegral -> iv) }, _) ->
      return $ \(x :: SInt32) -> doNeg (iv `rel` x) &&& fact x
    (_, ConstantC ConstantInt { constantIntValue = (fromIntegral -> iv)}) ->
      return $ \(x :: SInt32) -> doNeg (x `rel` iv) &&& fact x
    _ -> return fact

data CmpOperand = FuncallOperand Value -- the callee (external func or func)
                | ConstIntOperand Int
                | Neither

callFuncOrConst :: Value -> CmpOperand
callFuncOrConst v =
  case valueContent' v of
    ConstantC ConstantInt { constantIntValue = iv } ->
      ConstIntOperand (fromIntegral iv)
    InstructionC CallInst { callFunction = callee } ->
      FuncallOperand callee
    _ -> Neither

-- | FIXME here we need to pass in all of the conditions that are active
-- for this block.  We can do this by looking at the control dependence
-- graph to see the list of conditions.  Then we have to decide if each one
-- is true or false at the current location.
--
-- Walk backwards in the CFG; each conditional branch that gets us to
-- where we came from gives us the truth assignment of that condition.
-- What should we do if there is more than one predecessor?  Not a
-- problem, just stop (we don't know a fact)

extractErrorHandlingCode :: Function -> BlockReturns
                            -> (SInt32 -> SBool) -> SummaryType
                            -> CmpPredicate -> Value -> Value
                            -> BasicBlock -> BasicBlock
                            -> MaybeT Analysis ErrorDescriptor
extractErrorHandlingCode f brets inducedFacts s p v1 v2 tt ft = do
  rel <- liftMaybe $ cmpPredicateToRelation p
  (trueFormula, falseFormula) <- cmpToFormula inducedFacts s rel v1 v2
  case isSat trueFormula of
    True -> branchToErrorDescriptor f brets tt -- `debug` "-->Taking first branch"
    False -> case isSat falseFormula of
      True -> branchToErrorDescriptor f brets ft -- `debug` "-->Taking second branch"
      False -> fail "Error not checked"

cmpToFormula :: (SInt32 -> SBool)
                -> SummaryType
                -> (SInt32 -> SInt32 -> SBool, Bool)
                -> Value
                -> Value
                -> MaybeT Analysis (SInt32 -> SBool, SInt32 -> SBool)
cmpToFormula inducedFacts s (rel, isIneqCmp) v1 v2 = do
  ics <- lift $ analysisEnvironment indirectCallSummary
  ds <- lift $ analysisEnvironment dependencySummary
  st <- lift analysisGet
  let v1' = callFuncOrConst v1
      v2' = callFuncOrConst v2
      ecs = errorCodes st
  case (v1', v2') of
    (FuncallOperand callee, ConstIntOperand i)
      | S.member i ecs && isIneqCmp -> fail "Ignore inequality against error codes"
      | otherwise -> do
        let callees = callTargets ics callee
        rv <- errorReturnValue ds s callees
        let i' = fromIntegral i
            rv' = fromIntegral rv
            trueFormula = \(x :: SInt32) -> (x .== rv') &&& (x `rel` i') &&& inducedFacts x
            falseFormula = \(x :: SInt32) -> (x .== rv') &&& bnot (x `rel` i') &&& inducedFacts x
        return (trueFormula, falseFormula)
    (ConstIntOperand i, FuncallOperand callee)
      | S.member i ecs && isIneqCmp -> fail "Ignore inequality against error codes"
      | otherwise -> do
        let callees = callTargets ics callee
        rv <- errorReturnValue ds s callees
        let i' = fromIntegral i
            rv' = fromIntegral rv
            trueFormula = \(x :: SInt32) -> (x .== rv') &&& (i' `rel` x) &&& inducedFacts x
            falseFormula = \(x :: SInt32) -> (x .== rv') &&& bnot (i' `rel` x) &&& inducedFacts x
        return (trueFormula, falseFormula)
    _ -> fail "cmpToFormula"

cmpPredicateToRelation :: CmpPredicate -> Maybe (SInt32 -> SInt32 -> SBool, Bool)
cmpPredicateToRelation p =
  case p of
    ICmpEq -> return ((.==), False)
    ICmpNe -> return ((./=), False)
    ICmpUgt -> return ((.>), True)
    ICmpUge -> return ((.>=), False)
    ICmpUlt -> return ((.<), True)
    ICmpUle -> return ((.<=), False)
    ICmpSgt -> return ((.>), True)
    ICmpSge -> return ((.>=), False)
    ICmpSlt -> return ((.<), True)
    ICmpSle -> return ((.<=), False)
    _ -> fail "cmpPredicateToRelation is a floating point comparison"

isSat :: (SInt32 -> SBool) -> Bool
isSat = unsafePerformIO . isSatisfiable

errorReturnValue :: DependencySummary -> SummaryType -> [Value] -> MaybeT Analysis Int
errorReturnValue _ _ [] = fail "No call targets"
errorReturnValue ds s [callee] = do
  fsumm <- liftMaybe $ lookupFunctionSummary ds (ErrorSummary s mempty) callee
  liftMaybe $ errRetVal fsumm
errorReturnValue ds s (callee:rest) = do
  fsumm <- liftMaybe $ lookupFunctionSummary ds (ErrorSummary s mempty) callee
  rv <- liftMaybe $ errRetVal fsumm
  mapM_ (checkOtherErrorReturns rv) rest
  return rv
  where
    checkOtherErrorReturns rv c = do
      fsumm <- liftMaybe $ lookupFunctionSummary ds (ErrorSummary s mempty) c
      rv' <- liftMaybe $ errRetVal fsumm
      when (rv' /= rv) $ emitWarning Nothing "ErrorAnalysis" ("Mismatched error return codes for indirect call " ++ show (valueName callee))

-- FIXME: Whatever is calling this needs to be modified to be able to
-- check *multiple* error codes.  It is kind of doing the right thing
-- now just because sorted order basically works here
errRetVal :: [FuncAnnotation] -> Maybe Int
errRetVal [] = Nothing
errRetVal (FAReportsErrors _ ract : _) = do
--  act <- F.find isIntRet es
  case ract of
    ReturnConstantInt is ->
      case F.toList is of
        [] -> Nothing
        i:_ -> return i
    ReturnConstantPtr is ->
      case F.toList is of
        [] -> Nothing
        i:_ -> return i
errRetVal (_:rest) = errRetVal rest


callTargets :: IndirectCallSummary -> Value -> [Value]
callTargets ics callee =
  case valueContent' callee of
    FunctionC _ -> [callee]
    ExternalFunctionC _ -> [callee]
    _ -> indirectCallInitializers ics callee

isErrRetAnnot :: FuncAnnotation -> Bool
isErrRetAnnot (FAReportsErrors _ _) = True
isErrRetAnnot _ = False

-- FIXME This needs to get all of the blocks that are in this branch
-- (successors of bb and control dependent on the branch).
branchToErrorDescriptor :: Function -> BlockReturns -> BasicBlock
                           -> MaybeT Analysis ErrorDescriptor
branchToErrorDescriptor f brs bb = do
  let rcs = blockReturns brs bb -- `debug` show brs
  constantRcs <- liftMaybe $ mapM retValToConstantInt rcs -- `debug` show rcs
  case null constantRcs {- `debug` show constantRcs -} of
    True -> fail "Non-constant return value"
    False ->
      let rcon = if functionReturnsPointer f
                 then ReturnConstantPtr
                 else ReturnConstantInt
          ract = rcon (S.fromList constantRcs)
          acts = foldr instToAction [] (basicBlockInstructions bb)
      in return $! ErrorDescriptor (S.fromList acts) ract [] -- `debug` show constantRcs

retValToConstantInt :: Value -> Maybe Int
retValToConstantInt v =
  case valueContent' v of
    ConstantC ConstantInt { constantIntValue = (fromIntegral -> iv) } ->
      return iv
    _ -> Nothing

functionReturnsPointer :: Function -> Bool
functionReturnsPointer f =
  case functionReturnType f of
    TypePointer _ _ -> True
    _ -> False

instToAction ::Instruction -> [ErrorAction] -> [ErrorAction]
instToAction i acc =
  case i of
    CallInst { callFunction = (valueContent' -> FunctionC f)
             , callArguments = (map fst -> args)
             } ->
      let fname = identifierAsString (functionName f)
          argActs = foldr callArgActions mempty (zip [0..] args)
      in FunctionCall fname argActs : acc
    _ -> acc

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

argumentIndex :: Argument -> Int
argumentIndex a = aix
  where
    f = argumentFunction a
    Just aix = elemIndex a (functionParameters f)

singlePredecessor :: CFG -> BasicBlock -> Maybe BasicBlock
singlePredecessor cfg bb =
  case basicBlockPredecessors cfg bb of
    [singlePred] -> return singlePred
    _ -> Nothing

isFuncallAct :: ErrorAction -> Bool
isFuncallAct a =
  case a of
    FunctionCall _ _ -> True
    _ -> False

isErrorFuncCall :: Set String -> ErrorAction -> Bool
isErrorFuncCall funcSet errAct =
  case errAct of
    FunctionCall s _ -> S.member s funcSet
    _ -> False

liftMaybe :: Maybe a -> MaybeT Analysis a
liftMaybe Nothing = fail "liftMaybe"
liftMaybe (Just a) = return a
