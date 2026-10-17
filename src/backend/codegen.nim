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
    # <NOTE>#45: scoped symbol tables. Lookup walks from innermost to
    # outermost. Mirrors the sema scope model; shadowing produces a new
    # alloca per declaration and the outer one becomes visible again
    # after the block closes.
    scopes: seq[Table[string, LLVMValueRef]]
    varTypes: seq[Table[string, LLVMTypeRef]]

proc lookupVar(c: CodegenCtx, name: string): LLVMValueRef =
  for i in countdown(c.scopes.len - 1, 0):
    if c.scopes[i].hasKey(name): return c.scopes[i][name]
  nil

proc lookupVarType(c: CodegenCtx, name: string, default: LLVMTypeRef): LLVMTypeRef =
  for i in countdown(c.varTypes.len - 1, 0):
    if c.varTypes[i].hasKey(name): return c.varTypes[i][name]
  default

proc defineVar(c: var CodegenCtx, name: string, slot: LLVMValueRef,
               ty: LLVMTypeRef) =
  c.scopes[^1][name] = slot
  c.varTypes[^1][name] = ty

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

proc kindFromTypeName(name: string): TypeKind =
  ## <NOTE>#68: fallback for unit tests that build nkDecl by hand,
  ## bypassing sema. In normal flow n.typ is always set.
  case name
  of "Int", "I64": tyI64
  of "I8": tyI8
  of "U8": tyU8
  of "I16": tyI16
  of "U16": tyU16
  of "I32": tyI32
  of "U32": tyU32
  of "U64": tyU64
  of "Bool": tyBool
  else:
    raise newException(ValueError,
      "codegen: unknown declared type: " & name)

proc llvmIntType(c: CodegenCtx, kind: TypeKind): LLVMTypeRef =
  ## <NOTE>#64: LLVM has one iN per width; signedness matters only in
  ## operations (sdiv/udiv, icmp slt/ult), not in the type itself.
  case kind
  of tyI8, tyU8:   LLVMIntTypeInContext(c.ctx, 8)
  of tyI16, tyU16: LLVMIntTypeInContext(c.ctx, 16)
  of tyI32, tyU32: LLVMIntTypeInContext(c.ctx, 32)
  of tyI64, tyU64: c.i64
  of tyBool:       c.i1
  else:
    raise newException(AssertionDefect,
      "llvmIntType: not an int kind: " & $kind)

proc toBool(c: var CodegenCtx, v: LLVMValueRef): LLVMValueRef =
  ## Convert i64 value to i1 (non-zero = true).
  LLVMBuildICmp(c.builder, LLVMIntNE, v, LLVMConstInt(c.i64, 0, 0), "to_bool")

# <NOTE>#52: emitExpr needs emitStmt for nkBlock bodies; emitStmt needs
# emitExpr for values. Forward-declare emitStmt so both can coexist.
proc emitStmt(c: var CodegenCtx, n: Node): LLVMValueRef

proc emitExpr(c: var CodegenCtx, n: Node): LLVMValueRef =
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
  of nkCast:
    # <NOTE>#61: same-width passthrough only in 7c. Trunc/zext/sext in 7d.
    let v = emitExpr(c, n.castExpr)
    if n.castExpr.typ.kind == n.typ.kind:
      return v
    if n.castExpr.typ.kind == tyILit and n.typ.kind == tyI64:
      return v
    raise newException(ValueError,
      "codegen: width-changing cast not supported yet (7d)")
  of nkIdent:
    let slot = c.lookupVar(n.identName)
    if slot == nil:
      raise newException(ValueError,
        "codegen: undefined variable: " & n.identName)
    let loadName = n.identName & "_load"
    let ty = c.lookupVarType(n.identName, c.i64)
    LLVMBuildLoad2(c.builder, ty, slot, loadName.cstring)
  of nkBlock:
    # <NOTE>#49: value-block. Sema guarantees a value-block ends with
    # `is` (or is a grouping that yields its single stmt); statements
    # before `is` are emitted for effect.
    c.scopes.add initTable[string, LLVMValueRef]()
    c.varTypes.add initTable[string, LLVMTypeRef]()
    var val: LLVMValueRef = nil
    for stmt in n.stmts:
      if stmt.kind == nkIs:
        val = emitExpr(c, stmt.isValue)
      else:
        let v = emitStmt(c, stmt)
        if v != nil: val = v
    c.scopes.setLen(c.scopes.len - 1)
    c.varTypes.setLen(c.varTypes.len - 1)
    if val == nil:
      raise newException(ValueError,
        "codegen: value block without is")
    val
  of nkIs:
    # <NOTE>#50: `is` is normally consumed by emitExpr(nkBlock). This
    # case exists so emitExpr can recurse into a bare `is` if needed.
    emitExpr(c, n.isValue)
  of nkIf:
    # <NOTE>#46: value-if. Both branches must be value expressions
    # (literals, idents, binops). Statement branches (decl/assign/block)
    # need emitStmt's path, which is handled in emitStmt below.
    # <NOTE>#47: branch values must match the phi type. In Bool context
    # literals are iLit-emitted i64; convert them to i1 for the phi.
    if n.typ == nil or n.typ.kind == tyNul:
      raise newException(ValueError,
        "codegen: statement if in value position")
    let llvmTy = if n.typ.kind == tyBool: c.i1 else: c.i64
    var cond = emitExpr(c, n.ifCond)
    let condIsBool = n.ifCond.typ != nil and n.ifCond.typ.kind == tyBool
    if not condIsBool:
      cond = toBool(c, cond)
    let thenBB = LLVMCreateBasicBlockInContext(c.ctx, "then")
    let elseBB = LLVMCreateBasicBlockInContext(c.ctx, "else")
    let mergeBB = LLVMCreateBasicBlockInContext(c.ctx, "merge")
    LLVMAppendExistingBasicBlock(c.mainFn, thenBB)
    LLVMAppendExistingBasicBlock(c.mainFn, elseBB)
    LLVMAppendExistingBasicBlock(c.mainFn, mergeBB)
    discard LLVMBuildCondBr(c.builder, cond, thenBB, elseBB)
    LLVMPositionBuilderAtEnd(c.builder, thenBB)
    var thenVal = emitExpr(c, n.ifThen)
    if llvmTy == c.i1 and not (n.ifThen.typ != nil and n.ifThen.typ.kind == tyBool):
      thenVal = toBool(c, thenVal)
    discard LLVMBuildBr(c.builder, mergeBB)
    LLVMPositionBuilderAtEnd(c.builder, elseBB)
    var elseVal: LLVMValueRef
    if n.ifElse != nil:
      elseVal = emitExpr(c, n.ifElse)
      if llvmTy == c.i1 and not (n.ifElse.typ != nil and n.ifElse.typ.kind == tyBool):
        elseVal = toBool(c, elseVal)
    else:
      elseVal = LLVMConstInt(llvmTy, 0, 0)
    discard LLVMBuildBr(c.builder, mergeBB)
    LLVMPositionBuilderAtEnd(c.builder, mergeBB)
    let phi = LLVMBuildPhi(c.builder, llvmTy, "if_phi")
    var vals: array[2, LLVMValueRef]
    var blks: array[2, LLVMBasicBlockRef]
    vals[0] = thenVal; blks[0] = thenBB
    vals[1] = elseVal; blks[1] = elseBB
    LLVMAddIncoming(phi, addr vals[0], addr blks[0], 2)
    phi
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
    let declKind =
      if n.typ != nil: n.typ.kind
      else: kindFromTypeName(n.declType)
    let llvmTy = llvmIntType(c, declKind)
    let slot = LLVMBuildAlloca(c.builder, llvmTy, n.declName.cstring)
    c.defineVar(n.declName, slot, llvmTy)
    var initVal: LLVMValueRef
    if n.declInit == nil:
      initVal = LLVMConstInt(llvmTy, 0, 0)
    elif n.declInit.kind == nkInt:
      initVal = LLVMConstInt(llvmTy,
        cast[culonglong](n.declInit.intVal), 0)
    elif n.declInit.typ != nil and n.declInit.typ.kind == tyILit:
      # <NOTE>#65: sema-folded literal (nkUnary(-int), folded nkBinOp)
      # carries its final value in typ as iLit(N). Emit at slot width.
      initVal = LLVMConstInt(llvmTy,
        cast[culonglong](n.declInit.typ.value), 0)
    else:
      initVal = emitExpr(c, n.declInit)
      # <TODO>#66: coerce concrete source to slot width (7d-2). Check
      # only when both types are known; unit tests may leave typ nil.
      if n.declInit.typ != nil and n.typ != nil and
         n.declInit.typ.kind != n.typ.kind:
        raise newException(ValueError,
          "codegen: mismatched init type not supported yet (7d-2): " &
          $n.declInit.typ.kind & " -> " & $n.typ.kind)
    discard LLVMBuildStore(c.builder, initVal, slot)
    nil
  of nkAssign:
    let slot = c.lookupVar(n.assignName)
    if slot == nil:
      raise newException(ValueError,
        "codegen: assign to undeclared: " & n.assignName)
    let llvmTy = c.lookupVarType(n.assignName, c.i64)
    var val: LLVMValueRef
    if n.assignValue.kind == nkInt:
      val = LLVMConstInt(llvmTy,
        cast[culonglong](n.assignValue.intVal), 0)
    elif n.assignValue.typ != nil and n.assignValue.typ.kind == tyILit:
      val = LLVMConstInt(llvmTy,
        cast[culonglong](n.assignValue.typ.value), 0)
    else:
      val = emitExpr(c, n.assignValue)
      # <TODO>#66: coerce concrete source to slot width (7d-2). Check
      # only when both types are known.
      if n.assignValue.typ != nil and n.typ != nil and
         n.assignValue.typ.kind != n.typ.kind:
        raise newException(ValueError,
          "codegen: mismatched assign type not supported yet (7d-2): " &
          $n.assignValue.typ.kind & " -> " & $n.typ.kind)
    discard LLVMBuildStore(c.builder, val, slot)
    nil
  of nkInt, nkIdent, nkUnary, nkBinOp:
    emitExpr(c, n)
  of nkBlock:
    # <NOTE>#51: value-block delegates to emitExpr so `is` yields.
    # Statement-block (nul type) stays flat — no yield, last value wins.
    if n.typ != nil and n.typ.kind != tyNul:
      return emitExpr(c, n)
    c.scopes.add initTable[string, LLVMValueRef]()
    c.varTypes.add initTable[string, LLVMTypeRef]()
    var lastVal: LLVMValueRef = nil
    for s in n.stmts:
      let v = emitStmt(c, s)
      if v != nil: lastVal = v
    c.scopes.setLen(c.scopes.len - 1)
    c.varTypes.setLen(c.varTypes.len - 1)
    lastVal
  of nkIf:
    # <NOTE>#44: if with a non-nul type is a value — emit via emitExpr
    # (phi in merge block). Statement if — branches are statements.
    if n.typ != nil and n.typ.kind != tyNul:
      return emitExpr(c, n)
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
                     scopes: @[initTable[string, LLVMValueRef]()],
                     varTypes: @[initTable[string, LLVMTypeRef]()])

  var retVal: LLVMValueRef = nil
  var retType: LidwType = nil
  if program.kind == nkProgram:
    for stmt in program.stmts:
      let v = emitStmt(c, stmt)
      if v != nil:
        retVal = v
        retType = stmt.typ
  if retVal == nil:
    retVal = LLVMConstInt(i64, 0, 0)
  elif retType != nil:
    if retType.kind == tyBool:
      retVal = LLVMBuildZExt(builder, retVal, i64, "bool_to_i64")
    elif retType.kind in IntKinds and retType.kind != tyI64:
      # <NOTE>#67: main returns i64; narrow results are extended by
      # signedness. Unsigned uses zext, signed uses sext.
      if isSigned(retType):
        retVal = LLVMBuildSExt(builder, retVal, i64, "ret_sext")
      else:
        retVal = LLVMBuildZExt(builder, retVal, i64, "ret_zext")
  discard LLVMBuildRet(builder, retVal)

  var errMsg: cstring = nil
  let verifyOk = LLVMVerifyModule(llmod, ReturnStatus, addr errMsg)
  if verifyOk != 0:
    let msg = if errMsg != nil: $errMsg else: "<no message>"
    if errMsg != nil: LLVMDisposeMessage(errMsg)
    raise newException(ValueError, "LLVM verify failed: " & msg)

  result = $LLVMPrintModuleToString(llmod)
