# Codegen: LIDW AST -> LLVM IR text.

import std/tables
import ../parser/ast
import ./llvm_c

type
  CodegenCtx = object
    ctx: LLVMContextRef
    builder: LLVMBuilderRef
    i64: LLVMTypeRef
    vars: Table[string, LLVMValueRef]   ## name -> alloca

proc emitExpr(c: CodegenCtx, n: Node): LLVMValueRef =
  case n.kind
  of nkInt:
    LLVMConstInt(c.i64, cast[culonglong](n.intVal), 0)
  of nkUnary:
    case n.unop
    of uoNeg:
      LLVMBuildNeg(c.builder, emitExpr(c, n.operand), "neg")
  of nkBinOp:
    let lhs = emitExpr(c, n.left)
    let rhs = emitExpr(c, n.right)
    case n.op
    of boAdd: LLVMBuildAdd(c.builder, lhs, rhs, "add")
    of boSub: LLVMBuildSub(c.builder, lhs, rhs, "sub")
    of boMul: LLVMBuildMul(c.builder, lhs, rhs, "mul")
    of boDiv: LLVMBuildSDiv(c.builder, lhs, rhs, "div")
    of boMod: LLVMBuildSRem(c.builder, lhs, rhs, "rem")
    else:
      raise newException(ValueError,
        "codegen: unsupported binop: " & opStr(n.op))
  of nkIdent:
    let slot = c.vars.getOrDefault(n.identName)
    if slot == nil:
      raise newException(ValueError,
        "codegen: undefined variable: " & n.identName)
    LLVMBuildLoad2(c.builder, c.i64, slot, n.identName & "_load")
  else:
    raise newException(ValueError,
      "codegen: unsupported node: " & $n.kind)

proc emitStmt(c: var CodegenCtx, n: Node): LLVMValueRef =
  ## Emits one statement. Returns the value expression if n is a value
  ## expr (for main's return), nil for declarative statements.
  case n.kind
  of nkDecl:
    # <TODO>#41: alloca in current block; for non-linear control flow
    # these must go to the entry block.
    let slot = LLVMBuildAlloca(c.builder, c.i64, n.declName.cstring)
    c.vars[n.declName] = slot
    let initVal =
      if n.declInit != nil: emitExpr(c, n.declInit)
      else: LLVMConstInt(c.i64, 0, 0)
    discard LLVMBuildStore(c.builder, initVal, slot)
    nil
  of nkAssign:
    let slot = c.vars.getOrDefault(n.assignName)
    if slot == nil:
      raise newException(ValueError,
        "codegen: assign to undeclared: " & n.assignName)
    let val = emitExpr(c, n.assignValue)
    discard LLVMBuildStore(c.builder, val, slot)
    nil
  of nkInt, nkIdent, nkUnary, nkBinOp:
    emitExpr(c, n)
  else:
    raise newException(ValueError,
      "codegen: unsupported statement: " & $n.kind)

proc emitModule*(program: Node): string =
  ## Lower the program and return textual LLVM IR.
  ## <TODO>#39: temporary semantics — main returns the last value
  ## expression. Replace with real program semantics once `print`/side
  ## effects exist.
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

  var c = CodegenCtx(ctx: ctx, builder: builder, i64: i64,
                     vars: initTable[string, LLVMValueRef]())

  var retVal: LLVMValueRef = nil
  if program.kind == nkProgram:
    for stmt in program.stmts:
      let v = emitStmt(c, stmt)
      if v != nil:
        retVal = v
  if retVal == nil:
    retVal = LLVMConstInt(i64, 0, 0)
  discard LLVMBuildRet(builder, retVal)

  var errMsg: cstring = nil
  let verifyOk = LLVMVerifyModule(llmod, ReturnStatus, addr errMsg)
  if verifyOk != 0:
    let msg = if errMsg != nil: $errMsg else: "<no message>"
    if errMsg != nil: LLVMDisposeMessage(errMsg)
    raise newException(ValueError, "LLVM verify failed: " & msg)

  result = $LLVMPrintModuleToString(llmod)
