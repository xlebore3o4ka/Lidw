# LLVM C API binding smoke tests — lifecycle only.

import std/unittest
import std/strutils
import ../src/backend/llvm_c
import ../src/backend/codegen
import ../src/parser/ast
import ../src/types

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
    let ir = emitModule(p, "<expr>", false)
    check "define i64 @main" in ir
    check "ret i64 0" in ir

  test "emitModule single int":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkInt, intVal: 42)
    ])
    let ir = emitModule(p, "<expr>", false)
    check "ret i64 42" in ir

  test "emitModule addition constant-folds":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkBinOp, op: boAdd,
        left: Node(kind: nkInt, intVal: 1),
        right: Node(kind: nkInt, intVal: 2))
    ])
    let ir = emitModule(p, "<expr>", false)
    # LLVM IR builder constant-folds; no instruction survives.
    check "ret i64 3" in ir

  test "emitModule decl alloca/store":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", typ: i64Type(),
           declInit: Node(kind: nkInt, intVal: 10))
    ])
    let ir = emitModule(p, "<expr>", false)
    check "alloca i64" in ir
    check "store i64 10" in ir
    check "ret i64 0" in ir       # decl has no value; main returns 0

  test "emitModule decl then read":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", typ: i64Type(),
           declInit: Node(kind: nkInt, intVal: 10)),
      Node(kind: nkIdent, identName: "x")
    ])
    let ir = emitModule(p, "<expr>", false)
    check "store i64 10" in ir
    check "load i64" in ir
    check "ret i64 %" in ir

  test "emitModule decl no init defaults to 0":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", typ: i64Type(), declInit: nil)
    ])
    let ir = emitModule(p, "<expr>", false)
    check "store i64 0" in ir

  test "emitModule decl then add non-constant":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", typ: i64Type(),
           declInit: Node(kind: nkInt, intVal: 10)),
      Node(kind: nkBinOp, op: boAdd,
        left: Node(kind: nkIdent, identName: "x"),
        right: Node(kind: nkInt, intVal: 1))
    ])
    let ir = emitModule(p, "<expr>", false)
    check "load i64" in ir
    check "add i64 %" in ir

  test "emitModule assign stores to same slot":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", typ: i64Type(),
           declInit: Node(kind: nkInt, intVal: 10)),
      Node(kind: nkAssign, assignName: "x",
           assignValue: Node(kind: nkInt, intVal: 5)),
      Node(kind: nkIdent, identName: "x")
    ])
    let ir = emitModule(p, "<expr>", false)
    check "store i64 10" in ir
    check "store i64 5" in ir
    check "load i64" in ir

  test "emitModule Bool decl allocates i1 and converts init":
    # LLVM constant-folds icmp on constants; store i1 true is the result.
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "b", typ: boolType(),
           declInit: Node(kind: nkInt, intVal: 1))
    ])
    let ir = emitModule(p, "<expr>", false)
    check "alloca i1" in ir
    check "store i1 true" in ir

  test "emitModule cast Int to Int is passthrough":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", typ: i64Type(),
           declInit: Node(kind: nkInt, intVal: 5, typ: iLitType(5))),
      Node(kind: nkDecl, declName: "y", typ: i64Type(),
           declInit: Node(kind: nkCast, typ: i64Type(), castTarget: "Int",
             castExpr: Node(kind: nkIdent, identName: "x", typ: i64Type())))
    ])
    let ir = emitModule(p, "<expr>", false)
    check "load i64" in ir

  test "emitModule cast Int to Bool":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", typ: i64Type(),
           declInit: Node(kind: nkInt, intVal: 5, typ: iLitType(5))),
      Node(kind: nkDecl, declName: "b", typ: boolType(),
           declInit: Node(kind: nkCast, typ: boolType(), castTarget: "Bool",
             castExpr: Node(kind: nkIdent, identName: "x", typ: i64Type())))
    ])
    let ir = emitModule(p, "<expr>", false)
    check "icmp ne i64" in ir

  test "emitModule cast iLit to U8 emits at width":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "u", typ: u8Type(),
           declInit: Node(kind: nkCast, typ: u8Type(), castTarget: "U8",
             castExpr: Node(kind: nkInt, intVal: 300, typ: iLitType(300))))
    ])
    let ir = emitModule(p, "<expr>", false)
    check "store i8" in ir

  test "emitModule cast Bool to Int":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "b", typ: boolType(),
           declInit: Node(kind: nkInt, intVal: 1, typ: iLitType(1))),
      Node(kind: nkDecl, declName: "x", typ: i64Type(),
           declInit: Node(kind: nkCast, typ: i64Type(), castTarget: "Int",
             castExpr: Node(kind: nkIdent, identName: "b", typ: boolType())))
    ])
    let ir = emitModule(p, "<expr>", false)
    check "zext i1" in ir

  test "emitModule narrow decl allocates i8":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", typ: u8Type(),
           declInit: Node(kind: nkInt, intVal: 5, typ: iLitType(5)))
    ])
    let ir = emitModule(p, "<expr>", false)
    check "alloca i8" in ir
    check "store i8 5" in ir

  test "emitModule Bool decl no init stores i1 false":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "b", typ: boolType(), declInit: nil)
    ])
    let ir = emitModule(p, "<expr>", false)
    check "store i1 false" in ir

  test "emitModule if statement has basic blocks":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", typ: i64Type(),
           declInit: Node(kind: nkInt, intVal: 0)),
      Node(kind: nkIf,
        ifCond: Node(kind: nkInt, intVal: 1),
        ifThen: Node(kind: nkAssign, assignName: "x",
                     assignValue: Node(kind: nkInt, intVal: 5)),
        ifElse: Node(kind: nkAssign, assignName: "x",
                     assignValue: Node(kind: nkInt, intVal: 7)))
    ])
    let ir = emitModule(p, "<expr>", false)
    check "br i1" in ir
    check "br label" in ir
    check "then:" in ir
    check "else:" in ir
    check "merge:" in ir
    check "store i64 5" in ir
    check "store i64 7" in ir

  test "emitModule if without else jumps to merge":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", typ: i64Type(),
           declInit: Node(kind: nkInt, intVal: 0)),
      Node(kind: nkIf,
        ifCond: Node(kind: nkInt, intVal: 1),
        ifThen: Node(kind: nkAssign, assignName: "x",
                     assignValue: Node(kind: nkInt, intVal: 5)),
        ifElse: nil)
    ])
    let ir = emitModule(p, "<expr>", false)
    check "br i1" in ir
    check "then:" in ir
    check "merge:" in ir
    check "else:" notin ir

  test "emitModule block shadowing creates separate alloca":
    # Int x = 1 (Int x = 2 x) x  ->  two allocas named x, both stored
    let outerDecl = Node(kind: nkDecl, declName: "x", typ: i64Type(),
                         declInit: Node(kind: nkInt, intVal: 1))
    let innerDecl = Node(kind: nkDecl, declName: "x", typ: i64Type(),
                         declInit: Node(kind: nkInt, intVal: 2))
    let innerRead = Node(kind: nkIdent, identName: "x")
    let innerBlock = Node(kind: nkBlock, stmts: @[innerDecl, innerRead])
    let outerRead = Node(kind: nkIdent, identName: "x")
    let p = Node(kind: nkProgram, stmts: @[outerDecl, innerBlock, outerRead])
    let ir = emitModule(p, "<expr>", false)
    # LLVM auto-suffixes duplicate names; count store instructions as
    # the ground truth for "two declarations actually emitted".
    check "store i64 1" in ir
    check "store i64 2" in ir

  test "emitModule value loop with break expr has phi":
    # Int x = while 1 break 5  -> while.brk phi i64 + while.result phi i64
    let decl = Node(kind: nkDecl, declName: "x", typ: i64Type(),
                    declInit: Node(kind: nkWhile, typ: i64Type(),
                      whileCond: Node(kind: nkInt, intVal: 1, typ: iLitType(1)),
                      whileBody: Node(kind: nkBreak, typ: iLitType(5),
                        breakExpr: Node(kind: nkInt, intVal: 5, typ: iLitType(5)))))
    let p = Node(kind: nkProgram, stmts: @[decl])
    let ir = emitModule(p, "<expr>", false)
    check "while.brk = phi i64" in ir
    check "while.result = phi i64" in ir

  test "emitModule F64 decl alloca double":

    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", typ: f64Type(),
           declInit: Node(kind: nkFloat, floatVal: 1.5, typ: fLitType(1.5)))
    ])
    let ir = emitModule(p, "<expr>", false)
    check "alloca double" in ir
    check "store double 1.5" in ir

  test "emitModule iLit under F64 slot":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", typ: f64Type(),
           declInit: Node(kind: nkInt, intVal: 5, typ: iLitType(5)))
    ])
    let ir = emitModule(p, "<expr>", false)
    check "alloca double" in ir

    check "store double 5" in ir

  test "emitModule is in block yields value":

    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", typ: i64Type(),
           declInit: Node(kind: nkBlock, typ: i64Type(), stmts: @[
             Node(kind: nkIs, typ: iLitType(5),
                  isValue: Node(kind: nkInt, intVal: 5, typ: iLitType(5)))
           ]))
    ])
    let ir = emitModule(p, "<expr>", false)
    check "store i64 5" in ir

  test "emitModule is with prior stmts in block":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "x", typ: i64Type(),
           declInit: Node(kind: nkBlock, typ: i64Type(), stmts: @[
             Node(kind: nkDecl, declName: "y", typ: i64Type(),
                  declInit: Node(kind: nkInt, intVal: 10, typ: iLitType(10))),
             Node(kind: nkIs, typ: i64Type(),
                  isValue: Node(kind: nkIdent, identName: "y", typ: i64Type()))
           ]))
    ])
    let ir = emitModule(p, "<expr>", false)
    check "store i64 10" in ir
    check "load i64" in ir

  test "emitModule if branches with is yield via phi":
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "c", typ: boolType(),
           declInit: Node(kind: nkInt, intVal: 1, typ: iLitType(1))),
      Node(kind: nkDecl, declName: "x", typ: i64Type(),
           declInit: Node(kind: nkIf, typ: i64Type(),
             ifCond: Node(kind: nkIdent, identName: "c", typ: boolType()),
             ifThen: Node(kind: nkBlock, typ: i64Type(), stmts: @[
               Node(kind: nkIs, typ: iLitType(5),
                    isValue: Node(kind: nkInt, intVal: 5, typ: iLitType(5)))
             ]),
             ifElse: Node(kind: nkBlock, typ: i64Type(), stmts: @[
               Node(kind: nkIs, typ: iLitType(7),
                    isValue: Node(kind: nkInt, intVal: 7, typ: iLitType(7)))
             ])))
    ])
    let ir = emitModule(p, "<expr>", false)
    check "phi i64" in ir

  test "emitModule value-if produces phi":
    # non-constant cond so LLVM cannot fold the branches away.
    let p = Node(kind: nkProgram, stmts: @[
      Node(kind: nkDecl, declName: "c", typ: boolType(),
           declInit: Node(kind: nkInt, intVal: 1)),
      Node(kind: nkDecl, declName: "x", typ: i64Type(),
           declInit: Node(kind: nkIf, typ: i64Type(),
             ifCond: Node(kind: nkIdent, identName: "c", typ: boolType()),
             ifThen: Node(kind: nkInt, intVal: 10, typ: iLitType(10)),
             ifElse: Node(kind: nkInt, intVal: 20, typ: iLitType(20))))
    ])
    let ir = emitModule(p, "<expr>", false)
    check "if_phi = phi i64" in ir

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
