# LLVM C API binding smoke tests — lifecycle only.

import std/unittest
import std/strutils
import ../src/backend/llvm_c

suite "llvm-c bindings":
  test "create and dispose in order":
    let ctx = LLVMContextCreate()
    check ctx != nil
    let llmod = LLVMModuleCreateWithNameInContext("lidw_test", ctx)
    check llmod != nil
    let builder = LLVMCreateBuilderInContext(ctx)
    check builder != nil
    LLVMDisposeBuilder(builder)
    LLVMDisposeModule(llmod)
    LLVMContextDispose(ctx)

  test "printed IR contains main and ret 42":
    let ctx = LLVMContextCreate()
    let llmod = LLVMModuleCreateWithNameInContext("lidw_test3", ctx)
    let builder = LLVMCreateBuilderInContext(ctx)

    let i64 = LLVMInt64TypeInContext(ctx)
    let fnTy = LLVMFunctionType(i64, nil, 0, 0)
    let mainFn = LLVMAddFunction(llmod, "main", fnTy)
    let entry = LLVMAppendBasicBlockInContext(ctx, mainFn, "entry")
    LLVMPositionBuilderAtEnd(builder, entry)
    discard LLVMBuildRet(builder, LLVMConstInt(i64, 42, 0))

    let text = $LLVMPrintModuleToString(llmod)
    check "define i64 @main" in text
    check "ret i64 42" in text

    LLVMDisposeBuilder(builder)
    LLVMDisposeModule(llmod)
    LLVMContextDispose(ctx)

  test "main returns 42, verifies":
    let ctx = LLVMContextCreate()
    let llmod = LLVMModuleCreateWithNameInContext("lidw_test2", ctx)
    let builder = LLVMCreateBuilderInContext(ctx)

    let i64 = LLVMInt64TypeInContext(ctx)
    let fnTy = LLVMFunctionType(i64, nil, 0, 0)
    let mainFn = LLVMAddFunction(llmod, "main", fnTy)
    let entry = LLVMAppendBasicBlockInContext(ctx, mainFn, "entry")
    LLVMPositionBuilderAtEnd(builder, entry)

    let fortyTwo = LLVMConstInt(i64, 42, 0)
    discard LLVMBuildRet(builder, fortyTwo)

    var errMsg: cstring = nil
    let verifyOk = LLVMVerifyModule(llmod, ReturnStatus, addr errMsg)
    if verifyOk != 0:
      echo "verify failed: ", $errMsg
      LLVMDisposeMessage(errMsg)
    check verifyOk == 0

    LLVMDisposeBuilder(builder)
    LLVMDisposeModule(llmod)
    LLVMContextDispose(ctx)
