# Codegen: LIDW AST -> LLVM IR text.
# <NOTE>#37: Step 2 skeleton — ignores the program body for now and emits
# `main: i64 () { ret i64 0 }`. AST traversal lands in Step 3.

import ../parser/ast
import ./llvm_c

proc emitModule*(program: Node): string =
  ## Lower the program and return textual LLVM IR.
  ## <TODO>#38: Step 3 — walk program.stmts and emit real instructions.
  discard program

  let ctx = LLVMContextCreate()
  defer: LLVMContextDispose(ctx)
  let llmod = LLVMModuleCreateWithNameInContext("lidw", ctx)
  defer: LLVMDisposeModule(llmod)
  let builder = LLVMCreateBuilderInContext(ctx)
  defer: LLVMDisposeBuilder(builder)

  let i64 = LLVMInt64TypeInContext(ctx)
  let fnTy = LLVMFunctionType(i64, nil, 0, 0)
  let mainFn = LLVMAddFunction(llmod, "main", fnTy)
  let entry = LLVMAppendBasicBlockInContext(ctx, mainFn, "entry")
  LLVMPositionBuilderAtEnd(builder, entry)
  discard LLVMBuildRet(builder, LLVMConstInt(i64, 0, 0))

  var errMsg: cstring = nil
  let verifyOk = LLVMVerifyModule(llmod, ReturnStatus, addr errMsg)
  if verifyOk != 0:
    let msg = if errMsg != nil: $errMsg else: "<no message>"
    if errMsg != nil: LLVMDisposeMessage(errMsg)
    raise newException(ValueError, "LLVM verify failed: " & msg)

  let text = $LLVMPrintModuleToString(llmod)
  result = text
