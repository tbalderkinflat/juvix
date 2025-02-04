module Juvix.Compiler.Asm.Transformation.Prealloc where

import Data.HashMap.Strict qualified as HashMap
import Juvix.Compiler.Asm.Options
import Juvix.Compiler.Asm.Transformation.Base

computeMaxArgsNum :: InfoTable -> Int
computeMaxArgsNum tab = maximum (map (^. functionArgsNum) (HashMap.elems (tab ^. infoFunctions)))

computeCodePrealloc :: forall r. (Members '[Error AsmError, Reader Options] r) => Int -> InfoTable -> Code -> Sem r Code
computeCodePrealloc maxArgsNum tab code = prealloc <$> foldS sig code (0, [])
  where
    -- returns the maximum memory use and the mapping result (Code with the
    -- Prealloc instructions inserted)
    sig :: FoldSig StackInfo r (Int, Code)
    sig =
      FoldSig
        { _foldInfoTable = tab,
          _foldAdjust = second (const []),
          _foldInstr = const goInstr,
          _foldBranch = const goBranch,
          _foldCase = const goCase
        }

    goInstr :: CmdInstr -> (Int, Code) -> Sem r (Int, Code)
    goInstr instr@CmdInstr {..} acc@(k, c) = case _cmdInstrInstruction of
      AllocConstr tag ->
        return (k + size, cmd : c)
        where
          ci = lookupConstrInfo tab tag
          size = getConstrSize (ci ^. constructorRepresentation) (ci ^. constructorArgsNum)
      AllocClosure InstrAllocClosure {..} -> do
        opts <- ask
        let size = getClosureSize opts _allocClosureArgsNum
        return (k + size, cmd : c)
      ExtendClosure {} -> do
        opts <- ask
        let size = opts ^. optLimits . limitsClosureHeadSize + maxArgsNum
        return (k + size, cmd : c)
      Call {} -> return (0, cmd : prealloc acc)
      TailCall {} -> return (0, cmd : prealloc acc)
      CallClosures {} -> return (0, cmd : prealloc acc)
      TailCallClosures {} -> return (0, cmd : prealloc acc)
      Binop StrConcat -> do
        opts <- ask
        let size = opts ^. optLimits . limitsMaxStringSize
        return (k + size, cmd : c)
      ValShow -> do
        opts <- ask
        let size = opts ^. optLimits . limitsMaxStringSize
        return (k + size, cmd : c)
      _ -> return (k, cmd : c)
      where
        cmd = Instr instr

    goBranch :: CmdBranch -> (Int, Code) -> (Int, Code) -> (Int, Code) -> Sem r (Int, Code)
    goBranch cmd br1 br2 (_, c) = return (0, cmd' : c)
      where
        cmd' =
          Branch
            cmd
              { _cmdBranchTrue = prealloc br1,
                _cmdBranchFalse = prealloc br2
              }

    goCase :: CmdCase -> [(Int, Code)] -> Maybe (Int, Code) -> (Int, Code) -> Sem r (Int, Code)
    goCase cmd brs md (_, c) = return (0, cmd' : c)
      where
        cmd' =
          Case
            cmd
              { _cmdCaseBranches =
                  zipWith
                    CaseBranch
                    (map (^. caseBranchTag) (cmd ^. cmdCaseBranches))
                    (map prealloc brs),
                _cmdCaseDefault = fmap prealloc md
              }

    prealloc :: (Int, Code) -> Code
    prealloc (0, c) = c
    prealloc (n, c) = mkInstr (Prealloc (InstrPrealloc n)) : c

computeFunctionPrealloc :: (Members '[Error AsmError, Reader Options] r) => Int -> InfoTable -> FunctionInfo -> Sem r FunctionInfo
computeFunctionPrealloc maxArgsNum tab = liftCodeTransformation (computeCodePrealloc maxArgsNum tab)

computePrealloc :: (Members '[Error AsmError, Reader Options] r) => InfoTable -> Sem r InfoTable
computePrealloc tab =
  liftFunctionTransformation (computeFunctionPrealloc (computeMaxArgsNum tab) tab) tab

checkCodePrealloc :: forall r. (Members '[Error AsmError, Reader Options] r) => Int -> InfoTable -> Code -> Sem r Bool
checkCodePrealloc maxArgsNum tab code = do
  f <- foldS sig code id
  return $ f 0 >= 0
  where
    sig :: FoldSig StackInfo r (Int -> Int)
    sig =
      FoldSig
        { _foldInfoTable = tab,
          _foldAdjust = id,
          _foldInstr = const goInstr,
          _foldBranch = const goBranch,
          _foldCase = const goCase
        }

    goInstr :: CmdInstr -> (Int -> Int) -> Sem r (Int -> Int)
    goInstr CmdInstr {..} cont = case _cmdInstrInstruction of
      Prealloc InstrPrealloc {..} ->
        return $ \k -> if k < 0 then error "check prealloc" else cont _preallocWordsNum
      AllocConstr tag ->
        return $ \k -> cont (k - size)
        where
          ci = lookupConstrInfo tab tag
          size = getConstrSize (ci ^. constructorRepresentation) (ci ^. constructorArgsNum)
      AllocClosure InstrAllocClosure {..} -> do
        opts <- ask
        let size = getClosureSize opts _allocClosureArgsNum
        return $ \k -> cont (k - size)
      ExtendClosure {} -> do
        opts <- ask
        let size = opts ^. optLimits . limitsClosureHeadSize + maxArgsNum
        return $ \k -> cont (k - size)
      Binop StrConcat -> do
        opts <- ask
        let size = opts ^. optLimits . limitsMaxStringSize
        return $ \k -> cont (k - size)
      ValShow -> do
        opts <- ask
        let size = opts ^. optLimits . limitsMaxStringSize
        return $ \k -> cont (k - size)
      _ -> return id

    goBranch :: CmdBranch -> (Int -> Int) -> (Int -> Int) -> (Int -> Int) -> Sem r (Int -> Int)
    goBranch _ br1 br2 cont =
      return $ \k ->
        let k1 = br1 k
            k2 = br2 k
         in cont (min k1 k2)

    goCase :: CmdCase -> [Int -> Int] -> Maybe (Int -> Int) -> (Int -> Int) -> Sem r (Int -> Int)
    goCase _ brs md cont =
      return $ \k ->
        let ks = map (\f -> f k) brs
            kd = fmap (\f -> f k) md
            k' = min (minimum ks) (fromMaybe k kd)
         in cont k'

checkPrealloc :: Options -> InfoTable -> Bool
checkPrealloc opts tab =
  case run $ runError $ runReader opts sb of
    Left err -> error (show err)
    Right b -> b
  where
    sb :: Sem '[Reader Options, Error AsmError] Bool
    sb = allM (checkCodePrealloc (computeMaxArgsNum tab) tab . (^. functionCode)) (HashMap.elems (tab ^. infoFunctions))
