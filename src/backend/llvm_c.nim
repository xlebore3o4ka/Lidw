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
  LLVMMetadataRef* = ptr object
  LLVMDIBuilderRef* = ptr object
  LLVMDbgRecordRef* = ptr object
  LLVMTargetDataRef* = ptr object




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
proc LLVMSetTarget*(M: LLVMModuleRef, Triple: cstring)
  {.cdecl, importc: "LLVMSetTarget".}
proc LLVMSetDataLayout*(M: LLVMModuleRef, DataLayoutStr: cstring)
  {.cdecl, importc: "LLVMSetDataLayout".}
# <NOTE>#170: LLVMInitializeNativeTarget is `static inline` in
# llvm-c/Target.h and not exported from libLLVM. Call the concrete
# host-target initializers instead. Host is x86-64 here; on other
# hosts, swap the X86* family for the matching one.
proc LLVMInitializeX86TargetInfo*()
  {.cdecl, importc: "LLVMInitializeX86TargetInfo".}
proc LLVMInitializeX86Target*()
  {.cdecl, importc: "LLVMInitializeX86Target".}
proc LLVMInitializeX86TargetMC*()
  {.cdecl, importc: "LLVMInitializeX86TargetMC".}
proc LLVMInitializeX86AsmPrinter*()
  {.cdecl, importc: "LLVMInitializeX86AsmPrinter".}

proc LLVMGetDefaultTargetTriple*(): cstring
  {.cdecl, importc: "LLVMGetDefaultTargetTriple".}

proc LLVMCreateTargetData*(Triple: cstring): LLVMTargetDataRef
  {.cdecl, importc: "LLVMCreateTargetData".}
proc LLVMCopyStringRepOfTargetData*(TD: LLVMTargetDataRef): cstring
  {.cdecl, importc: "LLVMCopyStringRepOfTargetData".}
proc LLVMDisposeTargetData*(TD: LLVMTargetDataRef)
  {.cdecl, importc: "LLVMDisposeTargetData".}


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
proc LLVMStructTypeInContext*(C: LLVMContextRef,
                              ElementTypes: ptr LLVMTypeRef,
                              ElementCount: cuint,
                              Packed: LLVMBool): LLVMTypeRef
  {.cdecl, importc: "LLVMStructTypeInContext".}


# --- functions ---
proc LLVMAddFunction*(M: LLVMModuleRef, Name: cstring,
                      FunctionTy: LLVMTypeRef): LLVMValueRef
  {.cdecl, importc: "LLVMAddFunction".}
proc LLVMAppendBasicBlockInContext*(C: LLVMContextRef, Fn: LLVMValueRef,
                                    Name: cstring): LLVMBasicBlockRef
  {.cdecl, importc: "LLVMAppendBasicBlockInContext".}
proc LLVMPositionBuilderAtEnd*(Builder: LLVMBuilderRef, Block: LLVMBasicBlockRef)
  {.cdecl, importc: "LLVMPositionBuilderAtEnd".}
proc LLVMGetInsertBlock*(Builder: LLVMBuilderRef): LLVMBasicBlockRef
  {.cdecl, importc: "LLVMGetInsertBlock".}
proc LLVMGetBasicBlockTerminator*(BB: LLVMBasicBlockRef): LLVMValueRef
  {.cdecl, importc: "LLVMGetBasicBlockTerminator".}



# --- values ---
proc LLVMConstInt*(IntTy: LLVMTypeRef, N: culonglong,
                   SignExtend: LLVMBool): LLVMValueRef
  {.cdecl, importc: "LLVMConstInt".}

# --- instructions ---
proc LLVMBuildRet*(Builder: LLVMBuilderRef, V: LLVMValueRef): LLVMValueRef
  {.cdecl, importc: "LLVMBuildRet".}
proc LLVMBuildRetVoid*(Builder: LLVMBuilderRef): LLVMValueRef
  {.cdecl, importc: "LLVMBuildRetVoid".}
proc LLVMVoidTypeInContext*(C: LLVMContextRef): LLVMTypeRef
  {.cdecl, importc: "LLVMVoidTypeInContext".}


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
proc LLVMBuildExtractValue*(Builder: LLVMBuilderRef, AggVal: LLVMValueRef,
                            Index: cuint, Name: cstring): LLVMValueRef
  {.cdecl, importc: "LLVMBuildExtractValue".}


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
proc LLVMBuildUnreachable*(Builder: LLVMBuilderRef): LLVMValueRef
  {.cdecl, importc: "LLVMBuildUnreachable".}



# --- module flags ---

const
  LLVMModuleFlagBehaviorWarning* = 1.cint

# <NOTE>#163: LLVM 17+ signature: Val is LLVMMetadataRef, not
# LLVMValueRef. Passing a MetadataAsValue (Value*) where Metadata* is
# expected causes a segfault: different memory layouts.
proc LLVMAddModuleFlag*(M: LLVMModuleRef, Behavior: cint,
                        Key: cstring, KeyLen: csize_t,
                        Val: LLVMMetadataRef)
  {.cdecl, importc: "LLVMAddModuleFlag".}


# --- debug info (D.1a: setup only) ---

# <NOTE>#151: LLVM C API LLVMDWARFSourceLanguage: C89=0, C=1,

# Ada83=2, C++=3, ... (not the DWARF v4 numeric values). Use C=1.
# LLVMDWARFEmissionKind: None=0, Full=1, LineTablesOnly=2.
const
  LLVMDWARFSourceLanguageC* = 1.cint
  LLVMDWARFEmissionKindFull* = 1.cint



proc LLVMCreateDIBuilder*(M: LLVMModuleRef): LLVMDIBuilderRef
  {.cdecl, importc: "LLVMCreateDIBuilder".}
proc LLVMDisposeDIBuilder*(Builder: LLVMDIBuilderRef)
  {.cdecl, importc: "LLVMDisposeDIBuilder".}
proc LLVMDIBuilderFinalize*(Builder: LLVMDIBuilderRef)
  {.cdecl, importc: "LLVMDIBuilderFinalize".}
proc LLVMDIBuilderCreateFile*(Builder: LLVMDIBuilderRef,
                              Filename: cstring, FilenameLen: csize_t,
                              Directory: cstring, DirectoryLen: csize_t): LLVMMetadataRef
  {.cdecl, importc: "LLVMDIBuilderCreateFile".}
proc LLVMDIBuilderCreateCompileUnit*(Builder: LLVMDIBuilderRef,
                                     Lang: cint, File: LLVMMetadataRef,
                                     Producer: cstring, ProducerLen: csize_t,
                                     isOptimized: LLVMBool,
                                     Flags: cstring, FlagsLen: csize_t,
                                     RuntimeVer: cuint,
                                     SplitName: cstring, SplitNameLen: csize_t,
                                     Kind: cint, DWOId: cuint,
                                     SplitDebugInlining: LLVMBool,
                                     DebugInfoForProfiling: LLVMBool,
                                     SysRoot: cstring, SysRootLen: csize_t,
                                     SDK: cstring, SDKLen: csize_t): LLVMMetadataRef
  {.cdecl, importc: "LLVMDIBuilderCreateCompileUnit".}

# <NOTE>#167: LLVM 23 C signature:
#   CreateBasicType(Builder, Name, NameLen, SizeInBits, Encoding, Flags)
# There is no AlignInBits parameter. LLVMDWARFTypeEncoding and
# LLVMDIFlags are both uint32 in C.
proc LLVMDIBuilderCreateBasicType*(Builder: LLVMDIBuilderRef,
                                   Name: cstring, NameLen: csize_t,
                                   SizeInBits: culonglong,
                                   Encoding: cuint,
                                   Flags: cuint): LLVMMetadataRef
  {.cdecl, importc: "LLVMDIBuilderCreateBasicType".}


proc LLVMDIBuilderCreateSubroutineType*(Builder: LLVMDIBuilderRef,
                                        File: LLVMMetadataRef,
                                        ParameterTypes: ptr LLVMMetadataRef,
                                        NumParameterTypes: cuint,
                                        Flags: cint): LLVMMetadataRef
  {.cdecl, importc: "LLVMDIBuilderCreateSubroutineType".}
# <NOTE>#157: LLVM 15+ signature: Name is cstring, not metadata.
# Earlier versions had it as LLVMMetadataRef; we target LLVM 23.
proc LLVMDIBuilderCreateFunction*(Builder: LLVMDIBuilderRef,
                                  Scope: LLVMMetadataRef,
                                  Name: cstring, NameLen: csize_t,
                                  LinkageName: cstring, LinkageNameLen: csize_t,
                                  File: LLVMMetadataRef,
                                  LineNo: cuint,
                                  Ty: LLVMMetadataRef,
                                  IsLocalToUnit, IsDefinition: LLVMBool,
                                  ScopeLine: cuint, Flags: cint,
                                  IsOptimized: LLVMBool): LLVMMetadataRef
  {.cdecl, importc: "LLVMDIBuilderCreateFunction".}

proc LLVMSetSubprogram*(Fn: LLVMValueRef, SP: LLVMMetadataRef)
  {.cdecl, importc: "LLVMSetSubprogram".}

# <NOTE>#152: LLVM C API uses cint/cuint for DWARF constants.
# DW_ATE_signed = 0x05, DW_ATE_unsigned = 0x07, DW_ATE_boolean = 0x02.
const
  LLVMDWATEsigned* = 0x05.cint
  LLVMDWATEunsigned* = 0x07.cint
  LLVMDWATEboolean* = 0x02.cint

proc LLVMDIBuilderCreateDebugLocation*(Ctx: LLVMContextRef,
                                       Line, Column: cuint,
                                       Scope, InlinedAt: LLVMMetadataRef): LLVMMetadataRef
  {.cdecl, importc: "LLVMDIBuilderCreateDebugLocation".}
proc LLVMSetCurrentDebugLocation2*(Builder: LLVMBuilderRef, Loc: LLVMMetadataRef)
  {.cdecl, importc: "LLVMSetCurrentDebugLocation2".}
proc LLVMDIBuilderCreateAutoVariable*(Builder: LLVMDIBuilderRef,
                                      Scope: LLVMMetadataRef,
                                      Name: cstring, NameLen: csize_t,
                                      File: LLVMMetadataRef,
                                      LineNo: cuint,
                                      Ty: LLVMMetadataRef,
                                      AlwaysPreserve: LLVMBool,
                                      Flags: cuint,
                                      AlignInBits: cuint): LLVMMetadataRef
  {.cdecl, importc: "LLVMDIBuilderCreateAutoVariable".}
proc LLVMDIBuilderCreateExpression*(Builder: LLVMDIBuilderRef,
                                    Addr: ptr uint64,
                                    Length: csize_t): LLVMMetadataRef
  {.cdecl, importc: "LLVMDIBuilderCreateExpression".}
proc LLVMDIBuilderInsertDeclareRecordAtEnd*(Builder: LLVMDIBuilderRef,

                                            Storage: LLVMValueRef,
                                            VarInfo: LLVMMetadataRef,
                                            Expr: LLVMMetadataRef,
                                            DebugLoc: LLVMMetadataRef,
                                            Block: LLVMBasicBlockRef): LLVMDbgRecordRef
  {.cdecl, importc: "LLVMDIBuilderInsertDeclareRecordAtEnd".}

proc LLVMMetadataAsValue*(C: LLVMContextRef, MD: LLVMMetadataRef): LLVMValueRef
  {.cdecl, importc: "LLVMMetadataAsValue".}
proc LLVMValueAsMetadata*(Val: LLVMValueRef): LLVMMetadataRef
  {.cdecl, importc: "LLVMValueAsMetadata".}




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
