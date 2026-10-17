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

# --- verification ---
proc LLVMVerifyModule*(M: LLVMModuleRef,
                       Action: LLVMVerifierFailureAction,
                       OutMessage: ptr cstring): LLVMBool
  {.cdecl, importc: "LLVMVerifyModule".}
proc LLVMDisposeMessage*(Message: cstring)
  {.cdecl, importc: "LLVMDisposeMessage".}
