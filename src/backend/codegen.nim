# Codegen: LIDW AST -> LLVM IR text.

import std/tables
import ../parser/ast
import ../types
import ./llvm_c

type
  CodegenCtx = object
    ctx: LLVMContextRef
    builder: LLVMBuilderRef
    mainFn: LLVMValueRef
    i64: LLVMTypeRef
    i1: LLVMTypeRef
    vars: Table[string, LLVMValueRef]   ## name -> alloca
    varTypes: Table[string, LLVMTypeRef]  ## name -> slot LLVM type (i64 or i1)

proc cmpPredicate(op: BinOp): cint =
  case op
  of boEq: LLVMIntEQ
  of boNe: LLVMIntNE
  of boLt: LLVMIntSLT
  of boLe: LLVMIntSLE
  of boGt: LLVMIntSGT
  of boGe: LLVMIntSGE
  else:
    raise newException(ValueError, "cmpPredicate: not a comparison: " & opStr(op))

proc toBool(c: CodegenCtx, v: LLVMValueRef): LLVMValueRef =
  ## Convert i64 value to i1 (non-zero = true).
  LLVMBuildICmp(c.builder, LLVMIntNE, v, LLVMConstInt(c.i64, 0, 0), "to_bool")

proc emitExpr(c: CodegenCtx, n: Node): LLVMValueRef =
  case n.kind
  of nkInt:
    LLVMConstInt(c.i64, cast[culonglong](n.intVal), 0)
  of nkUnary:
    case n.unop
    of uoNeg:
      LLVMBuildNeg(c.builder, emitExpr(c, n.operand), "neg")
  of nkBinOp:
    case n.op
    of boAdd, boSub, boMul, boDiv, boMod:
      let lhs = emitExpr(c, n.left)
      let rhs = emitExpr(c, n.right)
      case n.op
      of boAdd: LLVMBuildAdd(c.builder, lhs, rhs, "add")
      of boSub: LLVMBuildSub(c.builder, lhs, rhs, "sub")
      of boMul: LLVMBuildMul(c.builder, lhs, rhs, "mul")
      of boDiv: LLVMBuildSDiv(c.builder, lhs, rhs, "div")
      of boMod: LLVMBuildSRem(c.builder, lhs, rhs, "rem")
      else: raise newException(ValueError, "unreachable")
    of boEq, boNe, boLt, boLe, boGt, boGe:
      # <NOTE>#43: comparisons operate on a common representation.
      # Int/iLit -> i64; Bool -> i1; mixed Int/iLit vs Bool is rejected
      # by sema (except Int vs iLit which are both i64 here).
      let lIsBool = n.left.typ != nil and n.left.typ.kind == tyBool
      let rIsBool = n.right.typ != nil and n.right.typ.kind == tyBool
      var lhs: LLVMValueRef
      var rhs: LLVMValueRef
      if lIsBool or rIsBool:
        lhs = if lIsBool: emitExpr(c, n.left) else: toBool(c, emitExpr(c, n.left))
        rhs = if rIsBool: emitExpr(c, n.right) else: toBool(c, emitExpr(c, n.right))
      else:
        lhs = emitExpr(c, n.left)
        rhs = emitExpr(c, n.right)
      LLVMBuildICmp(c.builder, cmpPredicate(n.op), lhs, rhs, "cmp")
  of nkIdent:
    let slot = c.vars.getOrDefault(n.identName)
    if slot == nil:
      raise newException(ValueError,
        "codegen: undefined variable: " & n.identName)
    let loadName = n.identName & "_load"
    let ty = c.varTypes.getOrDefault(n.identName, c.i64)
    LLVMBuildLoad2(c.builder, ty, slot, loadName.cstring)
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
    let llvmTy =
      if n.declType == "Bool": c.i1
      else: c.i64          # Int, I64, anything else sema already rejected
    let slot = LLVMBuildAlloca(c.builder, llvmTy, n.declName.cstring)
    c.vars[n.declName] = slot
    c.varTypes[n.declName] = llvmTy
    var initVal: LLVMValueRef
    if n.declInit == nil:
      initVal = LLVMConstInt(llvmTy, 0, 0)
    else:
      initVal = emitExpr(c, n.declInit)
      let initIsBool = n.declInit.typ != nil and n.declInit.typ.kind == tyBool
      if llvmTy == c.i1 and not initIsBool:
        initVal = toBool(c, initVal)
    discard LLVMBuildStore(c.builder, initVal, slot)
    nil
  of nkAssign:
    let slot = c.vars.getOrDefault(n.assignName)
    if slot == nil:
      raise newException(ValueError,
        "codegen: assign to undeclared: " & n.assignName)
    let llvmTy = c.varTypes.getOrDefault(n.assignName, c.i64)
    var val = emitExpr(c, n.assignValue)
    let valIsBool = n.assignValue.typ != nil and n.assignValue.typ.kind == tyBool
    if llvmTy == c.i1 and not valIsBool:
      val = toBool(c, val)
    discard LLVMBuildStore(c.builder, val, slot)
    nil
  of nkInt, nkIdent, nkUnary, nkBinOp:
    emitExpr(c, n)
  of nkBlock:
    # <NOTE>#45: codegen has no scope model yet; block stmts are emitted
    # flat. Vars declared in a block overwrite outer names in c.vars
    # (shadowing not modelled in codegen; sema already checked validity).
    var lastVal: LLVMValueRef = nil
    for s in n.stmts:
      let v = emitStmt(c, s)
      if v != nil: lastVal = v
    lastVal
  of nkIf:
    # <NOTE>#44: statement-position if — branches are statements, result
    # discarded. Value-if (in decl init) is 5d (phi).
    if n.typ != nil and n.typ.kind != tyNul:
      raise newException(ValueError,
        "codegen: if as value not implemented yet (5d)")
    var cond = emitExpr(c, n.ifCond)
    let condIsBool = n.ifCond.typ != nil and n.ifCond.typ.kind == tyBool
    if not condIsBool:
      cond = toBool(c, cond)
    let thenBB = LLVMCreateBasicBlockInContext(c.ctx, "then")
    let mergeBB = LLVMCreateBasicBlockInContext(c.ctx, "merge")
    var elseBB: LLVMBasicBlockRef
    if n.ifElse != nil:
      elseBB = LLVMCreateBasicBlockInContext(c.ctx, "else")
    else:
      elseBB = mergeBB
    LLVMAppendExistingBasicBlock(c.mainFn, thenBB)
    if n.ifElse != nil:
      LLVMAppendExistingBasicBlock(c.mainFn, elseBB)
    LLVMAppendExistingBasicBlock(c.mainFn, mergeBB)
    discard LLVMBuildCondBr(c.builder, cond, thenBB, elseBB)
    LLVMPositionBuilderAtEnd(c.builder, thenBB)
    discard emitStmt(c, n.ifThen)
    discard LLVMBuildBr(c.builder, mergeBB)
    if n.ifElse != nil:
      LLVMPositionBuilderAtEnd(c.builder, elseBB)
      discard emitStmt(c, n.ifElse)
      discard LLVMBuildBr(c.builder, mergeBB)
    LLVMPositionBuilderAtEnd(c.builder, mergeBB)
    nil
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
  let i1 = LLVMInt1TypeInContext(ctx)
  let fnTy = LLVMFunctionType(i64, nil, 0, 0)
  let mainFn = LLVMAddFunction(llmod, "main", fnTy)
  let entry = LLVMAppendBasicBlockInContext(ctx, mainFn, "entry")
  LLVMPositionBuilderAtEnd(builder, entry)

  var c = CodegenCtx(ctx: ctx, builder: builder, mainFn: mainFn,
                     i64: i64, i1: i1,
                     vars: initTable[string, LLVMValueRef](),
                     varTypes: initTable[string, LLVMTypeRef]())

  var retVal: LLVMValueRef = nil
  var retIsBool = false
  if program.kind == nkProgram:
    for stmt in program.stmts:
      let v = emitStmt(c, stmt)
      if v != nil:
        retVal = v
        retIsBool = stmt.typ != nil and stmt.typ.kind == tyBool
  if retVal == nil:
    retVal = LLVMConstInt(i64, 0, 0)
  elif retIsBool:
    retVal = LLVMBuildZExt(builder, retVal, i64, "bool_to_i64")
  discard LLVMBuildRet(builder, retVal)

  var errMsg: cstring = nil
  let verifyOk = LLVMVerifyModule(llmod, ReturnStatus, addr errMsg)
  if verifyOk != 0:
    let msg = if errMsg != nil: $errMsg else: "<no message>"
    if errMsg != nil: LLVMDisposeMessage(errMsg)
    raise newException(ValueError, "LLVM verify failed: " & msg)

  result = $LLVMPrintModuleToString(llmod)
