import Data.List ( foldl' )
import Data.Maybe ( fromJust )
import qualified Data.HashSet as S
import System.Environment ( getArgs )


import Data.LLVM
import Data.LLVM.CFG
import Data.LLVM.Analysis.Dataflow

import Foreign.Inference.Nullability

main = putStrLn "blank"

{-
main :: IO ()
main = do
  [ fname ] <- getArgs
  llvmModule <- parseLLVMBitcodeFile defaultParserOptions fname
  either putStrLn nullAnalysis llvmModule

isArgument :: Value -> Bool
isArgument Value { valueContent = Argument _ } = True
isArgument _ = False

nullAnalysis :: Module -> IO ()
nullAnalysis m = do
  let fs = moduleDefinedFunctions m
      cfgs = map mkCFG fs
      names = map (fromJust . valueName) fs
      na0 = emptyNullabilityAnalysis
      res = map (forwardDataflow na0) cfgs
      exitRes = map (\(x,y) -> x y) (zip res (map cfgExitValue cfgs))
      exitRes' = zip names $ map (S.filter isArgument) (map notNullablePtrs exitRes)
  mapM_ (putStrLn . show) exitRes'
  putStrLn "Fields:"
  let allInterestingFields = foldl' S.union S.empty (map notNullableFields exitRes)
  mapM_ (putStrLn . show) $ S.toList allInterestingFields
-}