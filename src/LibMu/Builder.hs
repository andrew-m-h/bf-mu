{-#LANGUAGE NoImplicitPrelude, FlexibleInstances#-}

module Builder where

import           Control.Monad.Trans.Class        (lift)
import           Control.Monad.Trans.Except
import           Control.Monad.Trans.State.Strict
import           LibMu.PrettyPrint                (PrettyPrint (..))
import           LibMu.TypeCheck                  (Log, checkAssign, checkAst,
                                                   checkExpression, retType)
import           Prelude hiding (EQ)
import           Control.Monad (void)
import qualified Data.Map.Strict                  as M
import           Text.Printf                      (printf)

import           LibMu.MuSyntax
import           LibMu.PrettyPrint
import           LibMu.TypeCheck
import           LibMu.MuPrelude


import Control.Monad.Trans.Writer
import Data.Monoid
import Data.Maybe (fromJust)

--Holds Program state for lookup by name
data BuilderState = BuilderState {
  builderVarID   :: Int,
  constants      :: M.Map String Declaration,
  typedefs       :: M.Map String Declaration,
  typedefOrd     :: [String], -- hold the order in which typedefs were declared
  funcsigs       :: M.Map String Declaration,
  funcdecls      :: M.Map String Declaration,
  globals        :: M.Map String Declaration,
  exposes        :: M.Map String Declaration,
  functionDefs   :: M.Map String Declaration,
  functionDefOrd :: [String] -- hold the order in which functions were declared
  }

data Function = Function {fnName :: String, fnVer :: String}

instance PrettyPrint (Either Error BuilderState) where
  ppFormat e = case e of
    Left err -> return err
    Right bs -> ppFormat bs

instance PrettyPrint BuilderState where
  ppFormat = ppFormat . flatten

flatten :: BuilderState -> Program
flatten (BuilderState _ cons tds tdOrd fs fdecl gl ex fdef fdefOrd) =
    case (,) <$> extractOrdered tds tdOrd <*> extractOrdered fdef fdefOrd of
      Nothing -> error "Failed to order typedefs appropriatly"
      Just (tdLst, fdLst) -> Program $ concat [
        tdLst,
        M.elems gl,
        M.elems cons,
        M.elems fdecl,
        M.elems fs,
        M.elems ex,
        fdLst
        ]

extractOrdered :: (Ord k) => M.Map k v -> [k] -> Maybe [v]
extractOrdered m mask = case mask of
  x:xs -> (:) <$> (M.lookup x m) <*> (extractOrdered m xs)
  [] -> pure []

checkBuilder :: BuilderState -> Log
checkBuilder = checkAst . flatten

emptyBuilderState :: BuilderState
emptyBuilderState = BuilderState 0 M.empty M.empty [] M.empty M.empty M.empty M.empty M.empty []

type Error = String
type Builder = ExceptT Error (State BuilderState)

runBuilder :: Builder a -> BuilderState -> Either Error a
runBuilder b s = evalState (runExceptT b) s

loadStdPrelude :: Builder ([UvmTypeDef], [SSAVariable], [FuncSig])
loadStdPrelude = loadPrelude preludeContents
                   
loadPrelude :: MuPrelude -> Builder ([UvmTypeDef], [SSAVariable], [FuncSig])
loadPrelude (types, consts, sigs) = do
  lift $ modify (\pState ->
                  pState {
                    typedefs = M.union (typedefs pState) (M.fromList tPrelude),
                    typedefOrd = (typedefOrd pState) ++ tNames,
                    constants = M.union (constants pState) (M.fromList cPrelude),
                    funcsigs = M.union (funcsigs pState) (M.fromList sPrelude)
                    }
                )
  return (types, map constVariable consts, sigs)
                 where
                   tNames = map uvmTypeDefName types
                   cNames = map (varID . constVariable) consts
                   sNames = map funcSigName sigs

                   tPrelude = zip tNames (map Typedef types)
                   cPrelude = zip cNames consts
                   sPrelude = zip sNames (map FunctionSignature sigs)

getVarID :: Builder Int
getVarID = lift $ gets builderVarID

getTypedef :: String -> Builder UvmTypeDef
getTypedef name = do
  pState <- lift $ gets typedefs
  case M.lookup name pState of
    Nothing -> throwE $ printf "Failed to find typedef: %s" name
    Just (Typedef tDef) -> return tDef
    _ -> throwE $ printf "Found non typedef with specified id: %s" name

getTypedefs :: [String] -> Builder [UvmTypeDef]
getTypedefs = mapM getTypedef

containsType :: String -> Builder Bool
containsType name = do
  pState <- lift $ gets typedefs
  case M.lookup name pState of
    Nothing -> return False
    Just (Typedef _) -> return True
    Just _ -> throwE $ printf "Found non typedef with specified id: %s" name

getConstant :: String -> Builder SSAVariable
getConstant name = do
  pState <- lift $ gets constants
  case M.lookup name pState of
    Nothing -> throwE $ printf "Failed to find constant: %s" name
    Just (ConstDecl var _) -> return var
    _ -> throwE $ printf "Found non constant with specified id: %s" name

getConstants :: [String] -> Builder [SSAVariable]
getConstants = mapM getConstant

containsConst :: String -> Builder Bool
containsConst name = do
  pState <- lift $ gets constants
  case M.lookup name pState of
    Nothing -> return False
    Just (ConstDecl _ _) -> return True
    Just _ -> throwE $ printf "Found non constant with specified id: %s" name

getFuncSig :: String -> Builder FuncSig
getFuncSig name = do
  pState <- lift $ gets funcsigs
  case M.lookup name pState of
   Nothing -> throwE $ printf "Failed to find constant: %s" name
   Just (FunctionSignature sig) -> return sig
   _ -> throwE $ printf "Found non function signature with specified id: %s" name

containsFuncSig :: String -> Builder Bool
containsFuncSig name = do
  pState <- lift $ gets funcsigs
  case M.lookup name pState of
    Nothing -> return False
    Just (FunctionSignature _) -> return True
    Just _ -> throwE $ printf "Found non function signature with specified id: %s" name


getGlobal :: String -> Builder SSAVariable
getGlobal name = do
  pState <- lift $ gets globals
  case M.lookup name pState of
    Nothing -> throwE $ printf "Failed to find global definition: %s" name
    Just (GlobalDef var _) -> return var
    _ -> throwE $ printf "Found non global with specified id: %s" name

containsGlobal :: String -> Builder Bool
containsGlobal name = do
  pState <- lift $ gets globals
  case M.lookup name pState of
    Nothing -> return False
    Just (GlobalDef _ _) -> return True
    Just _ -> return False


getFuncDecl :: String -> Builder FuncSig
getFuncDecl name = do
  pState <- lift $ gets funcdecls
  case M.lookup name pState of
    Nothing -> throwE $ printf "Failed to find funcdecl: %s" name
    Just (FunctionDecl _ sig) -> return sig
    Just _ -> throwE $ printf "Found non funcdecl with specified id: %s" name

containsFuncDecl :: String ->  Builder Bool
containsFuncDecl name = do
  pState <- lift $ gets funcdecls
  case M.lookup name pState of
    Nothing -> return False
    Just (FunctionDecl _ _) -> return True
    Just _ -> return False

getFuncDef :: String -> String -> Builder Declaration
getFuncDef name ver = do
  pState <- lift $ gets functionDefs
  case M.lookup (name ++ ver) pState of
    Nothing -> throwE $ printf "Failed to find global definition: %s" (name ++ ver)
    Just func@(FunctionDef _ _ _ _) -> return func
    Just _ -> throwE $ printf "Found non function def with specified id: %s" (name ++ ver)

containsFuncDef :: String -> String -> Builder Bool
containsFuncDef name ver = do
  pState <- lift $ gets functionDefs
  case M.lookup (name ++ ver) pState of
    Nothing -> return False
    Just (FunctionDef _ _ _ _) -> return True
    Just _ -> return False

putFuncSig :: String -> [UvmTypeDef] -> [UvmTypeDef] -> Builder FuncSig
putFuncSig name args ret = do
  let funcSig = FuncSig name args ret
  lift $ modify (\pState ->
                  pState {
                    funcsigs = M.insert name (FunctionSignature funcSig) (funcsigs pState)
                    })
  return funcSig

putFunction :: String -> String -> FuncSig -> Builder (Function, SSAVariable)
putFunction name ver sig = do
  lift $ modify $ (\pState ->
                    pState {
                      functionDefs = M.insert (name ++ ver) (FunctionDef name ver sig []) (functionDefs pState),
                      functionDefOrd = (functionDefOrd pState) ++ [name ++ ver]
                           })
  let funcRef = SSAVariable Global name (UvmTypeDef (printf "%s_ref" name) (FuncRef sig))
  return $ (Function name ver, funcRef)

putConstant :: String -> UvmTypeDef -> String -> Builder SSAVariable
putConstant name constType val = do
  let constVar = SSAVariable Global name constType
  lift $ modify (\pState ->
                  pState {
                    constants = M.insert name (ConstDecl constVar val) (constants pState)
                    })
  return constVar

putTypeDef :: String -> UvmType -> Builder UvmTypeDef
putTypeDef name uvmType = do
  let tDef = UvmTypeDef name uvmType
  lift $ modify (\pState ->
                  pState {
                    typedefs = M.insert name (Typedef tDef) (typedefs pState),
                    typedefOrd = (typedefOrd pState) ++ [name]
                    })
  return tDef

putFuncDecl :: String -> FuncSig -> Builder ()
putFuncDecl name fSig =
  lift $ modify (\pState -> pState {funcdecls = M.insert name (FunctionDecl name fSig) (funcdecls pState)
                                   })

putGlobal :: String -> UvmTypeDef -> Builder SSAVariable
putGlobal name dType = do
  let var = SSAVariable Global name (UvmTypeDef ("iref" ++ uvmTypeDefName dType) (IRef dType))
  lift $ modify (\pState ->
                  pState {
                    globals = M.insert name (GlobalDef var dType) (globals pState)
                    })
  return var

createVariable :: String -> UvmTypeDef -> SSAVariable
createVariable name typeVal = SSAVariable Local name typeVal

createVariables :: UvmTypeDef -> [String] -> [SSAVariable]
createVariables t lst = map (flip createVariable t) lst

createExecClause ::  BasicBlock -> [SSAVariable] -> BasicBlock -> [SSAVariable] -> ExceptionClause
createExecClause (BasicBlock name1 _ _ _ _) v1 (BasicBlock name2 _ _ _ _) v2 = ExceptionClause (DestinationClause name1 v1) (DestinationClause name2 v2)


putBasicBlock :: String -> [SSAVariable] -> Maybe SSAVariable -> Function -> Builder BasicBlock
putBasicBlock name vars exec fn@(Function func ver) = do
  FunctionDef fName fVer fSig fBody <- getFuncDef func ver
  let block = BasicBlock name vars exec [] (Return [])
  lift $ modify $ (\pState ->
                    pState {
                      functionDefs = M.insert (fName ++ fVer) (FunctionDef fName fVer fSig (block:fBody)) (functionDefs pState)
                           })
  return block

newtype BlockState = BlockState ([Assign], Maybe Expression)

instance Monoid BlockState where
  mempty = BlockState ([], Just $ Return [])
  mappend (BlockState (b1, t1)) (BlockState (b2, t2)) = case t2 of
    Nothing -> BlockState (b2 `mappend` b1, t1)
    Just term -> BlockState (b2 `mappend` b1, t2)



withBasicBlock :: String -> [SSAVariable] -> Maybe SSAVariable -> Function -> WriterT BlockState Builder () -> Builder BasicBlock
withBasicBlock name vars exec (Function func ver) prog = do
  let block = BasicBlock name vars exec [] (Return [])
  BlockState  (body, term) <- execWriterT prog
  let block' = block {basicBlockInstructions = body, basicBlockTerminst = fromJust term}
  FunctionDef fName fVer fSig fBody <- getFuncDef func ver
  lift $ modify $ (\pState ->
                    pState {
                      functionDefs = M.insert (fName ++ fVer) (FunctionDef fName fVer fSig (block':fBody)) (functionDefs pState)
                           })
  return block'
  
putBinOp :: BinaryOp -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putBinOp op v1@(SSAVariable _ _ opType) v2 exec = do
  n <- lift $ lift $ gets builderVarID
  let assignee = createVariable (printf "v%d" n) opType
  tell $ BlockState ([Assign [assignee] (BinaryOperation op opType v1 v2 exec)], Nothing)
  lift $ lift $ modify $ \pState -> pState {builderVarID = succ $ builderVarID pState}
  return assignee



putConvOp :: ConvertOp -> UvmTypeDef -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putConvOp op dest var exec = do
  n <- lift $ lift $ gets builderVarID
  let assignee = createVariable (printf "v%d" n) dest
  tell $ BlockState  ([Assign [assignee] (ConvertOperation op (varType var) dest var exec)], Nothing)
  lift $ lift $ modify $ \pState -> pState {builderVarID = succ $ builderVarID pState}
  return assignee


putCmpOp :: CompareOp -> SSAVariable -> SSAVariable -> WriterT BlockState Builder SSAVariable
putCmpOp op  v1@(SSAVariable _ _ opType) v2 = do
  n <- lift $ lift $ gets builderVarID
  let assignee = createVariable (printf "v%d" n) i1
  tell $ BlockState ([Assign [assignee] (CompareOperation op opType v1 v2)], Nothing)
  lift $ lift $ modify $ \pState -> pState {builderVarID = succ $ builderVarID pState}
  return assignee


putAtomicRMW :: AtomicRMWOp -> Bool -> MemoryOrder -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putAtomicRMW op ptr memOrd loc opnd exec = do
  n <- lift $ lift $ gets builderVarID
  let assignee = createVariable (printf "v%d" n) (varType opnd)
  tell $ BlockState ([Assign [assignee] (AtomicRMWOperation ptr memOrd op (varType opnd) loc opnd exec)], Nothing)
  lift $ lift $ modify $ \pState -> pState {builderVarID = succ $ builderVarID pState}
  return assignee


putCmpXchg :: Bool -> Bool -> MemoryOrder -> MemoryOrder -> SSAVariable -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder (SSAVariable, SSAVariable)
putCmpXchg ptr weak mem1 mem2 loc expec desir exec = do
  n <- lift $ lift $ gets builderVarID
  let ass1 = createVariable (printf "v%d" n) opndType
      ass2 = createVariable (printf "v%d" (succ n)) i1
  tell $ BlockState ([Assign [ass1, ass2] (CmpXchg ptr weak mem1 mem2 opndType loc expec desir exec)], Nothing)
  lift $ lift $ modify $ \pState -> pState {builderVarID = (+2) $ builderVarID pState}
  return (ass1, ass2)
  where
    opndType = case uvmTypeDefType $ varType loc of
      UPtr t -> t
      IRef t -> t
      _ -> varType loc
  

putFence :: MemoryOrder -> WriterT BlockState Builder ()
putFence memOrd = tell $ BlockState ([Assign [] (Fence memOrd)], Nothing)


putNew :: UvmTypeDef -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putNew t exec  = do
  n <- lift $ lift $ gets builderVarID
  let operation = New t exec
  assT <- let retT = head $ retType operation in lift $ putTypeDef (show retT) retT
  let assignee = createVariable (printf "v%d" n) assT
  tell $ BlockState ([Assign [assignee] operation], Nothing)
  lift $ lift $ modify $ \pState -> pState {builderVarID = succ $ builderVarID pState}
  return assignee


putNewHybrid :: UvmTypeDef -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putNewHybrid t len exec = do
  n <- lift $ lift $ gets builderVarID
  let operation = NewHybrid t (varType len) len exec
  assT <- let retT = head $ retType operation in lift $ putTypeDef (show retT) retT
  let assignee = createVariable (printf "v%d" n) assT
  tell $ BlockState ([Assign [assignee] operation], Nothing)
  lift $ lift $ modify $ \pState -> pState {builderVarID = succ $ builderVarID pState}
  return assignee


                                               
putAlloca :: UvmTypeDef -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putAlloca t exec = do
  n <- lift $ lift $ gets builderVarID
  let operation = Alloca t exec
  assT <- let retT = head $ retType operation in lift $ putTypeDef (show retT) retT
  let assignee = createVariable (printf "v%d" n) assT
  tell $ BlockState ([Assign [assignee] operation], Nothing)
  lift $ lift $ modify $ \pState -> pState {builderVarID = succ $ builderVarID pState}
  return assignee


putAllocaHybrid :: UvmTypeDef -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder SSAVariable
putAllocaHybrid t len exec = do
  n <- lift $ lift $ gets builderVarID
  let operation = AllocaHybrid t (varType len) len exec
  assT <- let retT = head $ retType operation in lift $ putTypeDef (show retT) retT
  let assignee = createVariable (printf "v%d" n) assT
  tell $ BlockState ([Assign [assignee] operation], Nothing)
  lift $ lift $ modify $ \pState -> pState {builderVarID = succ $ builderVarID pState}
  return assignee
  


setTermInstRet :: [SSAVariable] -> WriterT BlockState Builder ()
setTermInstRet rets = 
  tell $ BlockState ([], Just $ Return rets)


setTermInstThrow :: SSAVariable -> WriterT BlockState Builder ()
setTermInstThrow var = 
  tell $ BlockState ([], Just $ Throw var)


putCall :: [SSAVariable] -> SSAVariable -> FuncSig -> [SSAVariable] -> Maybe ExceptionClause -> Maybe [SSAVariable] -> WriterT BlockState Builder ()
putCall assignee func sig args exec alive =
  tell $ BlockState ([Assign assignee (Call sig func args exec (KeepAlive <$> alive))], Nothing)
  


putCCall :: [SSAVariable] ->  CallConvention -> UvmTypeDef -> FuncSig -> SSAVariable -> [SSAVariable] -> Maybe ExceptionClause -> Maybe [SSAVariable] -> WriterT BlockState Builder ()
putCCall assignee callConv t sig callee args exec alive = 
  tell $ BlockState ([Assign assignee (CCall callConv t sig callee args exec (KeepAlive <$> alive))], Nothing)
  

setTermInstTailCall :: FuncSig -> SSAVariable -> [SSAVariable] -> WriterT BlockState Builder ()
setTermInstTailCall sig callee args = 
  tell $ BlockState ([], Just $ TailCall sig callee args)
  

setTermInstBranch :: BasicBlock -> [SSAVariable] -> WriterT BlockState Builder ()
setTermInstBranch (BasicBlock dest _ _ _ _) vars =
  tell $ BlockState ([], Just $ Branch1 $ DestinationClause dest vars)
  

setTermInstBranch2 :: SSAVariable -> BasicBlock -> [SSAVariable] -> BasicBlock -> [SSAVariable] -> WriterT BlockState Builder ()
setTermInstBranch2 cond (BasicBlock trueBlock _ _ _ _) trueVars (BasicBlock falseBlock _ _ _ _) falseVars =
  tell $ BlockState ([], Just $  Branch2 cond (DestinationClause trueBlock trueVars) (DestinationClause falseBlock falseVars))
  
{-
putWatchPoint :: [SSAVariable] -> SSAVariable -> Int -> [UvmTypeDef] -> Block -> [SSAVariable] -> Block -> [SSAVariable] -> Maybe (Block, [SSAVariable]) -> Maybe [SSAVariable] -> WriterT BlockState Builder [SSAVariable]
putWatchPoint assignee name wpid ts (Block dis _) disArgs (Block ena _) enaArgs wpexec alive block = block {
    basicBlockInstructions = (Assign assignee (WatchPoint name wpid ts (DestinationClause dis disArgs) (DestinationClause ena enaArgs) wp (KeepAlive <$> alive))):(basicBlockInstructions block)
    }
  where
    wp = case wpexec of
      Nothing -> Nothing
      Just (Block wpBlock _, wpVars) -> Just $ WPExceptionClause $ DestinationClause wpBlock wpVars


putTrap :: [SSAVariable] -> SSAVariable -> [UvmTypeDef] -> Maybe ExceptionClause -> Maybe [SSAVariable] -> WriterT BlockState Builder [SSAVariable]
putTrap assignee name ts exec alive block = block {
  basicBlockInstructions = (Assign assignee (Trap name ts exec (KeepAlive <$> alive))):(basicBlockInstructions block)
  }


setTermInstWatchPoint :: SSAVariable -> Int -> [UvmTypeDef] -> Block -> [SSAVariable] -> Block -> [SSAVariable] -> Maybe (Block, [SSAVariable]) -> Maybe [SSAVariable] -> WriterT BlockState Builder [SSAVariable]
setTermInstWatchPoint name wpid ts (Block dis _) disArgs (Block ena _) enaArgs wpexec alive block = block {
    basicBlockTerminst = WatchPoint name wpid ts (DestinationClause dis disArgs) (DestinationClause ena enaArgs) wp (KeepAlive <$> alive)
    }
  where
    wp = case wpexec of
      Nothing -> Nothing
      Just (Block wpBlock _, wpVars) -> Just $ WPExceptionClause $ DestinationClause wpBlock wpVars


setTermInstTrap :: SSAVariable -> [UvmTypeDef] -> Maybe ExceptionClause -> Maybe [SSAVariable] -> WriterT BlockState Builder [SSAVariable]
setTermInstTrap name ts exec alive block = block {
  basicBlockTerminst = Trap name ts exec (KeepAlive <$> alive)
  }

setTermInstWPBranch :: Int -> Block -> [SSAVariable] -> Block -> [SSAVariable] -> WriterT BlockState Builder [SSAVariable]
setTermInstWPBranch wpid (Block disBlock _) disArgs (Block enaBlock _) enaArgs block = block {
  basicBlockTerminst = WPBranch wpid (DestinationClause disBlock disArgs) (DestinationClause enaBlock enaArgs)
  }

setTermInstSwitch :: SSAVariable -> Block -> [SSAVariable] -> [(SSAVariable, Block, [SSAVariable])] -> WriterT BlockState Builder [SSAVariable]
setTermInstSwitch cond (Block defBlock _) defArgs blocks block = block {
  basicBlockTerminst = Switch (varType cond) cond (DestinationClause defBlock defArgs) (map toBlocks blocks)
  }
  where
    toBlocks :: (SSAVariable, Block, [SSAVariable]) -> (SSAVariable, DestinationClause)
    toBlocks (cond, (Block block _), args) = (cond, DestinationClause block args)

setTermInstSwapStack :: SSAVariable -> CurStackClause -> NewStackClause -> Maybe ExceptionClause -> Maybe [SSAVariable] -> WriterT BlockState Builder [SSAVariable]
setTermInstSwapStack swappee csClause nsClause exec alive block = block {
  basicBlockTerminst = SwapStack swappee csClause nsClause exec (KeepAlive <$> alive)
  }

putNewThread :: SSAVariable -> SSAVariable -> NewStackClause -> Maybe ExceptionClause -> WriterT BlockState Builder [SSAVariable]
putNewThread assignee stack nsClause exec block = block {
  basicBlockInstructions = (Assign [assignee] (NewThread stack nsClause exec)):(basicBlockInstructions block)
  }

putComminst :: [SSAVariable] -> String -> [String] -> [UvmTypeDef] -> [FuncSig] -> [SSAVariable] -> Maybe ExceptionClause -> Maybe [SSAVariable] -> WriterT BlockState Builder [SSAVariable]
putComminst assignee name flags types sigs args exec alive block = block {
  basicBlockInstructions = (Assign assignee (Comminst name (toMaybe $ map Flag flags) (toMaybe types) (toMaybe sigs) (toMaybe args) exec (KeepAlive <$> alive))):(basicBlockInstructions block)
  }
  where
    toMaybe :: [a] -> Maybe [a]
    toMaybe lst = case lst of
      [] -> Nothing
      _  -> Just lst

putLoad :: SSAVariable -> Bool -> Maybe MemoryOrder -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder [SSAVariable]
putLoad assignee ptr memOrd var exec block = block {
  basicBlockInstructions = (Assign [assignee] (Load ptr memOrd vType var  exec)):(basicBlockInstructions block)
  }
  where
    vType :: UvmTypeDef
    vType = case uvmTypeDefType $ varType var of
      IRef t -> t
      UPtr t -> t
      _ -> undefined --varType var --errorful type, but let it fail elsewhere

putStore :: Bool -> Maybe MemoryOrder -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder [SSAVariable]
putStore ptr memOrd loc newVal exec block = block {
  basicBlockInstructions = (Assign [] (Store ptr memOrd locType loc newVal exec)):(basicBlockInstructions block)
  }
  where
    locType :: UvmTypeDef
    locType = case uvmTypeDefType $ varType loc of
      IRef t -> t
      UPtr t -> t
      _ -> varType loc --errorful type, but let it fail elsewhere

putExtractValueS1 :: SSAVariable -> Int -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder [SSAVariable]
putExtractValueS1 assignee index opnd exec block = block {
  basicBlockInstructions = (Assign [assignee] (ExtractValueS (varType opnd) index opnd exec)):(basicBlockInstructions block)
  }

putInsertValueS :: SSAVariable -> Int -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder [SSAVariable]
putInsertValueS assignee index opnd newVal exec block = block {
  basicBlockInstructions = (Assign [assignee] (InsertValueS (varType opnd) index newVal opnd exec)):(basicBlockInstructions block)
  }

putExtractValue :: SSAVariable -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder [SSAVariable]
putExtractValue assignee opnd index exec block = block {
  basicBlockInstructions = (Assign [assignee] (ExtractValue (varType opnd) (varType index) opnd index exec)):(basicBlockInstructions block)
  }

putInsertValue :: SSAVariable -> SSAVariable -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder [SSAVariable]
putInsertValue assignee opnd index newVal exec block = block {
  basicBlockInstructions = (Assign [assignee] (InsertValue (varType opnd) (varType index) opnd index newVal exec)):(basicBlockInstructions block)
  }

putShuffleVector :: SSAVariable -> SSAVariable -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder [SSAVariable]
putShuffleVector assignee v1 v2 mask exec block = block {
  basicBlockInstructions = (Assign [assignee] (ShuffleVector (varType v1) (varType mask) v1 v2 mask exec)):(basicBlockInstructions block)
  }


putGetIRef :: SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder [SSAVariable]
putGetIRef assignee opnd exec block = block {
  basicBlockInstructions = (Assign [assignee] (GetIRef opndType opnd exec)):(basicBlockInstructions block)
  }
  where
    opndType :: UvmTypeDef
    opndType = case uvmTypeDefType $ varType opnd of
      Ref t -> t
      _ -> varType opnd --errorful type, but let it fail elsewhere


putGetFieldIRef :: SSAVariable -> Bool -> Int -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder [SSAVariable]
putGetFieldIRef assignee ptr index opnd exec block = block {
  basicBlockInstructions = (Assign [assignee] (GetFieldIRpef ptr opndType index opnd exec )):(basicBlockInstructions block)
  }
  where
    opndType :: UvmTypeDef
    opndType = case uvmTypeDefType $ varType opnd of
      IRef t -> t
      UPtr t -> t
      _ -> varType opnd --errorful type, but let it fail elsewhere

putGetElemIRef :: SSAVariable -> Bool -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder [SSAVariable]
putGetElemIRef assignee ptr opnd index exec block = block {
  basicBlockInstructions = (Assign [assignee] (GetElemIRef ptr opndType (varType index) opnd index exec)):(basicBlockInstructions block)
  }
  where
    opndType :: UvmTypeDef
    opndType = case uvmTypeDefType $ varType opnd of
      IRef t -> t
      UPtr t -> t
      _ -> varType opnd --errorful type, but let it fail elsewhere


putShiftIRef :: SSAVariable -> Bool -> SSAVariable -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder [SSAVariable]
putShiftIRef assignee ptr opnd offset exec block = block {
  basicBlockInstructions = (Assign [assignee] (ShiftIRef ptr opndType (varType offset) opnd offset exec)):(basicBlockInstructions block)
  }
  where
    opndType :: UvmTypeDef
    opndType = case uvmTypeDefType $ varType opnd of
      IRef t -> t
      UPtr t -> t
      _ -> varType opnd --errorful type, but let it fail elsewhere


putGetVarPartIRef :: SSAVariable -> Bool -> SSAVariable -> Maybe ExceptionClause -> WriterT BlockState Builder [SSAVariable]
putGetVarPartIRef assignee ptr opnd exec block = block {
  basicBlockInstructions = (Assign [assignee] (GetVarPartIRef ptr opndType opnd exec)):(basicBlockInstructions block)
  }
  where
    opndType :: UvmTypeDef
    opndType = case uvmTypeDefType $ varType opnd of
      IRef t -> t
      UPtr t -> t
      _ -> varType opnd --errorful type, but let it fail elsewhere


putComment :: String -> WriterT BlockState Builder [SSAVariable]
putComment str block = block {
  basicBlockInstructions = (Assign [] (Comment str)):(basicBlockInstructions block)
  }
-}
