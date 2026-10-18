# Minimal LLVM C API bindings for LIDW.
# <NOTE>#35: passL at module scope propagates to every binary that imports
# this module (bin/lidw, tests). LLVM 23 ships as a single shared lib.
# Opaque handle types: distinct ptr objects so the compiler keeps them apart.
# <NOTE>#36: LLVMBool is cint in C; cint everywhere for ABI safety.

{.passL: "-lLLVM-23".}

type
  LLVMContextRef* = ptr object
  LLVMModuleRef*  = ptr object
  LLVMBuilderRef* = ptr object
  LLVMValueRef*   = ptr object
  LLVMTypeRef*    = ptr object
  LLVMBasicBlockRef* = ptr object

  LLVMBool* = cint

  LLVMVerifierFailureAction* {.pure.} = enum
    AbortProcess = 0
    PrintMessage = 1
    ReturnStatus = 2

# --- context ---
proc LLVMContextCreate*(): LLVMContextRef
  {.cdecl, importc: "LLVMContextCreate".}
proc LLVMContextDispose*(C: LLVMContextRef)
  {.cdecl, importc: "LLVMContextDispose".}

# --- module ---
proc LLVMModuleCreateWithNameInContext*(ModuleID: cstring,
                                        C: LLVMContextRef): LLVMModuleRef
  {.cdecl, importc: "LLVMModuleCreateWithNameInContext".}
proc LLVMDisposeModule*(M: LLVMModuleRef)
  {.cdecl, importc: "LLVMDisposeModule".}

# --- builder ---
proc LLVMCreateBuilderInContext*(C: LLVMContextRef): LLVMBuilderRef
  {.cdecl, importc: "LLVMCreateBuilderInContext".}
proc LLVMDisposeBuilder*(Builder: LLVMBuilderRef)
  {.cdecl, importc: "LLVMDisposeBuilder".}

# --- types ---
proc LLVMInt64TypeInContext*(C: LLVMContextRef): LLVMTypeRef
  {.cdecl, importc: "LLVMInt64TypeInContext".}
proc LLVMFunctionType*(ReturnType: LLVMTypeRef,
                       ParamTypes: ptr LLVMTypeRef,
                       ParamCount: cuint,
                       IsVarArg: LLVMBool): LLVMTypeRef
  {.cdecl, importc: "LLVMFunctionType".}

# --- functions ---
proc LLVMAddFunction*(M: LLVMModuleRef, Name: cstring,
                      FunctionTy: LLVMTypeRef): LLVMValueRef
  {.cdecl, importc: "LLVMAddFunction".}
proc LLVMAppendBasicBlockInContext*(C: LLVMContextRef, Fn: LLVMValueRef,
                                    Name: cstring): LLVMBasicBlockRef
  {.cdecl, importc: "LLVMAppendBasicBlockInContext".}
proc LLVMPositionBuilderAtEnd*(Builder: LLVMBuilderRef, Block: LLVMBasicBlockRef)
  {.cdecl, importc: "LLVMPositionBuilderAtEnd".}

# --- values ---
proc LLVMConstInt*(IntTy: LLVMTypeRef, N: culonglong,
                   SignExtend: LLVMBool): LLVMValueRef
  {.cdecl, importc: "LLVMConstInt".}

# --- instructions ---
proc LLVMBuildRet*(Builder: LLVMBuilderRef, V: LLVMValueRef): LLVMValueRef
  {.cdecl, importc: "LLVMBuildRet".}

# --- arithmetic ---
proc LLVMBuildAdd*(Builder: LLVMBuilderRef, LHS, RHS: LLVMValueRef,
                   Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMBuildAdd".}
proc LLVMBuildSub*(Builder: LLVMBuilderRef, LHS, RHS: LLVMValueRef,
                   Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMBuildSub".}
proc LLVMBuildMul*(Builder: LLVMBuilderRef, LHS, RHS: LLVMValueRef,
                   Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMBuildMul".}
proc LLVMBuildSDiv*(Builder: LLVMBuilderRef, LHS, RHS: LLVMValueRef,
                    Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMBuildSDiv".}
proc LLVMBuildSRem*(Builder: LLVMBuilderRef, LHS, RHS: LLVMValueRef,
                    Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMBuildSRem".}
proc LLVMBuildUDiv*(Builder: LLVMBuilderRef, LHS, RHS: LLVMValueRef,
                    Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMBuildUDiv".}
proc LLVMBuildURem*(Builder: LLVMBuilderRef, LHS, RHS: LLVMValueRef,
                    Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMBuildURem".}
proc LLVMBuildNeg*(Builder: LLVMBuilderRef, V: LLVMValueRef,
                   Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMBuildNeg".}

# --- variables (opaque pointers, LLVM 15+) ---
proc LLVMBuildAlloca*(Builder: LLVMBuilderRef, Ty: LLVMTypeRef,
                      Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMBuildAlloca".}
proc LLVMBuildStore*(Builder: LLVMBuilderRef, Val: LLVMValueRef,
                     Ptr: LLVMValueRef): LLVMValueRef
  {.cdecl, importc: "LLVMBuildStore".}
proc LLVMBuildLoad2*(Builder: LLVMBuilderRef, Ty: LLVMTypeRef,
                     PointerVal: LLVMValueRef, Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMBuildLoad2".}

# --- Bool infrastructure ---
# <NOTE>#42: LLVMIntPredicate values from llvm-c/Core.h.
# signed compares for Int, eq/ne for both Int and Bool.
const
  LLVMIntEQ*  = 32.cint
  LLVMIntNE*  = 33.cint
  LLVMIntUGT* = 34.cint
  LLVMIntUGE* = 35.cint
  LLVMIntULT* = 36.cint
  LLVMIntULE* = 37.cint
  LLVMIntSGT* = 38.cint
  LLVMIntSGE* = 39.cint
  LLVMIntSLT* = 40.cint
  LLVMIntSLE* = 41.cint

proc LLVMInt1TypeInContext*(C: LLVMContextRef): LLVMTypeRef
  {.cdecl, importc: "LLVMInt1TypeInContext".}
proc LLVMIntTypeInContext*(C: LLVMContextRef, NumBits: cuint): LLVMTypeRef
  {.cdecl, importc: "LLVMIntTypeInContext".}
proc LLVMBuildTrunc*(Builder: LLVMBuilderRef, Val: LLVMValueRef,
                     DestTy: LLVMTypeRef, Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMBuildTrunc".}
proc LLVMBuildSExt*(Builder: LLVMBuilderRef, Val: LLVMValueRef,
                    DestTy: LLVMTypeRef, Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMBuildSExt".}
proc LLVMBuildICmp*(Builder: LLVMBuilderRef, Op: cint,
                    LHS, RHS: LLVMValueRef, Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMBuildICmp".}
proc LLVMBuildZExt*(Builder: LLVMBuilderRef, Val: LLVMValueRef,
                    DestTy: LLVMTypeRef, Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMBuildZExt".}

# --- control flow ---
proc LLVMCreateBasicBlockInContext*(C: LLVMContextRef, Name: cstring): LLVMBasicBlockRef
  {.cdecl, importc: "LLVMCreateBasicBlockInContext".}
proc LLVMAppendExistingBasicBlock*(Fn: LLVMValueRef, BB: LLVMBasicBlockRef)
  {.cdecl, importc: "LLVMAppendExistingBasicBlock".}
proc LLVMBuildBr*(Builder: LLVMBuilderRef,
                  Dest: LLVMBasicBlockRef): LLVMValueRef
  {.cdecl, importc: "LLVMBuildBr".}
proc LLVMBuildCondBr*(Builder: LLVMBuilderRef, If: LLVMValueRef,
                      Then, Else: LLVMBasicBlockRef): LLVMValueRef
  {.cdecl, importc: "LLVMBuildCondBr".}
proc LLVMBuildPhi*(Builder: LLVMBuilderRef, Ty: LLVMTypeRef,
                   Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMBuildPhi".}
proc LLVMAddIncoming*(PhiNode: LLVMValueRef,
                      IncomingValues: ptr LLVMValueRef,
                      IncomingBlocks: ptr LLVMBasicBlockRef,
                      Count: cuint)
  {.cdecl, importc: "LLVMAddIncoming".}

proc LLVMPointerTypeInContext*(C: LLVMContextRef,
                               AddressSpace: cuint): LLVMTypeRef
  {.cdecl, importc: "LLVMPointerTypeInContext".}

# --- globals and printf helpers ---
proc LLVMInt8TypeInContext*(C: LLVMContextRef): LLVMTypeRef
  {.cdecl, importc: "LLVMInt8TypeInContext".}
proc LLVMInt32TypeInContext*(C: LLVMContextRef): LLVMTypeRef
  {.cdecl, importc: "LLVMInt32TypeInContext".}
proc LLVMConstStringInContext*(C: LLVMContextRef, Str: cstring,
                               Length: cuint,
                               DontNullTerminate: LLVMBool): LLVMValueRef
  {.cdecl, importc: "LLVMConstStringInContext".}
proc LLVMAddGlobal*(M: LLVMModuleRef, Ty: LLVMTypeRef,
                    Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMAddGlobal".}
proc LLVMSetInitializer*(GlobalVar: LLVMValueRef, ConstantVal: LLVMValueRef)
  {.cdecl, importc: "LLVMSetInitializer".}
proc LLVMSetGlobalConstant*(GlobalVar: LLVMValueRef, IsConstant: LLVMBool)
  {.cdecl, importc: "LLVMSetGlobalConstant".}
proc LLVMSetLinkage*(Global: LLVMValueRef, Linkage: cint)
  {.cdecl, importc: "LLVMSetLinkage".}
proc LLVMTypeOf*(Val: LLVMValueRef): LLVMTypeRef
  {.cdecl, importc: "LLVMTypeOf".}

# <NOTE>#102: LLVMLinkage.Private = 9 in llvm-c/Core.h. Private globals
# are not exported in the printed module, but are valid operands.
const
  LLVMPrivateLinkage* = 9.cint

# --- call-related ---
proc LLVMGetNamedFunction*(M: LLVMModuleRef, Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMGetNamedFunction".}
proc LLVMGetParam*(Fn: LLVMValueRef, Index: cuint): LLVMValueRef
  {.cdecl, importc: "LLVMGetParam".}
proc LLVMBuildCall2*(Builder: LLVMBuilderRef, Ty: LLVMTypeRef,
                     Fn: LLVMValueRef, Args: ptr LLVMValueRef,
                     NumArgs: cuint, Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMBuildCall2".}

# --- verification ---
proc LLVMVerifyModule*(M: LLVMModuleRef,
                       Action: LLVMVerifierFailureAction,
                       OutMessage: ptr cstring): LLVMBool
  {.cdecl, importc: "LLVMVerifyModule".}
proc LLVMDisposeMessage*(Message: cstring)
  {.cdecl, importc: "LLVMDisposeMessage".}

# --- printing ---
proc LLVMPrintModuleToString*(M: LLVMModuleRef): cstring
  {.cdecl, importc: "LLVMPrintModuleToString".}
