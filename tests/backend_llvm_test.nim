# LLVM C API binding smoke tests — lifecycle only.

import std/unittest
import std/strutils
import ../src/backend/llvm_c
import ../src/backend/codegen
import ../src/parser/ast

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

  test "emitModule empty program returns 0":
    let p = Node(kind: nkProgram, stmts: @[])
    let ir = emitModule(p)
    check "define i64 @main" in ir
    check "ret i64 0" in ir

  test "emitModule single int":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkInt, intVal: 42)
    ])
    let ir = emitModule(p)
    check "ret i64 42" in ir

  test "emitModule addition constant-folds":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkBinOp, op: boAdd,
        left: Node(kind: nkInt, intVal: 1),
        right: Node(kind: nkInt, intVal: 2))
    ])
    let ir = emitModule(p)
    # LLVM IR builder constant-folds; no instruction survives.
    check "ret i64 3" in ir

  test "emitModule decl alloca/store":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", declType: "Int",
           declInit: Node(kind: nkInt, intVal: 10))
    ])
    let ir = emitModule(p)
    check "alloca i64" in ir
    check "store i64 10" in ir
    check "ret i64 0" in ir       # decl has no value; main returns 0

  test "emitModule decl then read":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", declType: "Int",
           declInit: Node(kind: nkInt, intVal: 10)),
      Node(kind: nkIdent, identName: "x")
    ])
    let ir = emitModule(p)
    check "store i64 10" in ir
    check "load i64" in ir
    check "ret i64 %" in ir

  test "emitModule decl no init defaults to 0":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", declType: "Int", declInit: nil)
    ])
    let ir = emitModule(p)
    check "store i64 0" in ir

  test "emitModule decl then add non-constant":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", declType: "Int",
           declInit: Node(kind: nkInt, intVal: 10)),
      Node(kind: nkBinOp, op: boAdd,
        left: Node(kind: nkIdent, identName: "x"),
        right: Node(kind: nkInt, intVal: 1))
    ])
    let ir = emitModule(p)
    check "load i64" in ir
    check "add i64 %" in ir

  test "emitModule assign stores to same slot":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", declType: "Int",
           declInit: Node(kind: nkInt, intVal: 10)),
      Node(kind: nkAssign, assignName: "x",
           assignValue: Node(kind: nkInt, intVal: 5)),
      Node(kind: nkIdent, identName: "x")
    ])
    let ir = emitModule(p)
    check "store i64 10" in ir
    check "store i64 5" in ir
    check "load i64" in ir

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
