# Codegen: LIDW AST -> LLVM IR text.

import std/[tables, hashes]
import ../parser/ast

# <NOTE>#128: Node is a ref; pointer identity is the right key for
# per-declaration alloca slots (shadowing creates distinct nodes).
proc hash(n: Node): Hash = hash(cast[pointer](n))

import ../types
import ./llvm_c

type
  CodegenCtx = object
    ctx: LLVMContextRef
    module: LLVMModuleRef
    builder: LLVMBuilderRef
    mainFn: LLVMValueRef
    i64: LLVMTypeRef
    i1: LLVMTypeRef
    # <NOTE>#104: printf is declared once, lazily, on first builtin print.
    printfFn: LLVMValueRef
    printfTy: LLVMTypeRef
    printfFmt: LLVMValueRef
    curFnRetKind: TypeKind  ## ret kind of the fn whose body is emitted
    loopExits: seq[LLVMBasicBlockRef]
      ## <NOTE>#133: innermost last. `break` emits `br` to loopExits[^1].
    loopContinues: seq[LLVMBasicBlockRef]
      ## <NOTE>#140: innermost last. `continue` emits `br` to
      ## loopContinues[^1] (the condition block).

    declSlots: Table[Node, LLVMValueRef]

      ## <NOTE>#123: alloca is hoisted to the function entry block so
      ## that a decl inside a loop body (loops not yet, but coming)
      ## does not re-allocate on every iteration. Keyed by AST node:
      ## each nkDecl gets exactly one slot, regardless of shadowing
      ## (different nodes, different slots).


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

proc llvmIntType(c: CodegenCtx, kind: TypeKind): LLVMTypeRef

proc kindSigned(k: TypeKind): bool =
  k in {tyI8, tyI16, tyI32, tyI64}

proc kindBitWidth(k: TypeKind): int =
  case k
  of tyI8, tyU8: 8
  of tyI16, tyU16: 16
  of tyI32, tyU32: 32
  of tyI64, tyU64: 64
  else:
    raise newException(AssertionDefect,
      "kindBitWidth: not an int kind: " & $k)

proc cmpPredicate(op: BinOp, targetKind: TypeKind): cint =
  # <NOTE>#69: signedness of the target kind picks slt/ult family.
  # Eq/Ne are sign-agnostic. Bool comparisons come here with target
  # kind Bool; only Eq/Ne reach this path (ordering on Bool is a
  # sema error).
  if targetKind == tyBool:
    case op
    of boEq: return LLVMIntEQ
    of boNe: return LLVMIntNE
    else:
      raise newException(ValueError,
        "cmpPredicate: Bool with " & opStr(op))
  let signed = kindSigned(targetKind)
  case op
  of boEq: LLVMIntEQ
  of boNe: LLVMIntNE
  of boLt: (if signed: LLVMIntSLT else: LLVMIntULT)
  of boLe: (if signed: LLVMIntSLE else: LLVMIntULE)
  of boGt: (if signed: LLVMIntSGT else: LLVMIntUGT)
  of boGe: (if signed: LLVMIntSGE else: LLVMIntUGE)
  else:
    raise newException(ValueError,
      "cmpPredicate: not a comparison: " & opStr(op))

proc promoteIntKindsCG(a, b: TypeKind): TypeKind =
  ## <NOTE>#70: mirrors sema promoteIntKinds; codegen needs the common
  ## kind to pick one LLVM width for both operands.
  if a == b: return a
  let aSig = kindSigned(a)
  let bSig = kindSigned(b)
  if aSig == bSig:
    return if kindBitWidth(a) >= kindBitWidth(b): a else: b
  let sKind = if aSig: a else: b
  let uKind = if aSig: b else: a
  let c = max(kindBitWidth(sKind), kindBitWidth(uKind) + 1)
  case c
  of 1..8: tyI8
  of 9..16: tyI16
  of 17..32: tyI32
  of 33..64: tyI64
  else:
    raise newException(ValueError,
      "codegen: no common kind for " & $a & " and " & $b)

proc commonKindFor(a, b: LidwType): TypeKind =
  ## <NOTE>#71: common Int kind for a comparison. Both operands are
  ## Int or iLit here (Bool handled separately; sema rejected the rest).
  if a.kind == tyILit and b.kind == tyILit: return tyI64
  if a.kind == tyILit: return b.kind
  if b.kind == tyILit: return a.kind
  promoteIntKindsCG(a.kind, b.kind)

proc coerceInt(c: var CodegenCtx, v: LLVMValueRef,
               fromKind, toKind: TypeKind): LLVMValueRef =
  ## <NOTE>#72: extend by source signedness, truncate on shrink,
  ## pass through on same width (including iN -> uN, same bits).
  if fromKind == toKind: return v
  let fw = kindBitWidth(fromKind)
  let tw = kindBitWidth(toKind)
  if fw < tw:
    let toTy = llvmIntType(c, toKind)
    if kindSigned(fromKind):
      LLVMBuildSExt(c.builder, v, toTy, "sext")
    else:
      LLVMBuildZExt(c.builder, v, toTy, "zext")
  elif fw > tw:
    let toTy = llvmIntType(c, toKind)
    LLVMBuildTrunc(c.builder, v, toTy, "trunc")
  else:
    v

proc nodeKindOr(n: Node, default: TypeKind): TypeKind =
  ## <NOTE>#75: unit tests build nodes by hand without sema; typ may be
  ## nil. Default to i64 in that case (the only width test fixtures use).
  if n.typ != nil: n.typ.kind else: default

proc emitOperand(c: var CodegenCtx, n: Node, targetKind: TypeKind): LLVMValueRef

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
proc emitWhileExpr(c: var CodegenCtx, n: Node): LLVMValueRef

proc fnLLVMType(c: CodegenCtx, fnT: LidwType): LLVMTypeRef


# <NOTE>#105: printf is declared lazily at first builtin print. The
# format string is a private constant global, reused across calls.
proc ensurePrintf(c: var CodegenCtx) =
  if c.printfFn != nil: return
  let fmtVal = LLVMConstStringInContext(c.ctx, "%ld\n".cstring, 4, 0)
  let fmtArrTy = LLVMTypeOf(fmtVal)
  let fmtGlobal = LLVMAddGlobal(c.module, fmtArrTy, "print_fmt")
  LLVMSetInitializer(fmtGlobal, fmtVal)
  LLVMSetGlobalConstant(fmtGlobal, 1)
  LLVMSetLinkage(fmtGlobal, LLVMPrivateLinkage)
  c.printfFmt = fmtGlobal
  let i32Ty = LLVMInt32TypeInContext(c.ctx)
  var paramTys: array[1, LLVMTypeRef] = [LLVMPointerTypeInContext(c.ctx, 0)]
  let fnTy = LLVMFunctionType(i32Ty, addr paramTys[0], 1, 1)
  c.printfTy = fnTy
  c.printfFn = LLVMAddFunction(c.module, "printf", fnTy)

proc collectDecls(n: Node, acc: var seq[Node]) =

  ## <NOTE>#124: depth-first walk, collect every nkDecl that will need
  ## a stack slot. Fn decls are skipped (they are emitted by pass 1
  ## of emitModule, not as locals). Recurse into declInit, if-branches,
  ## blocks, and expressions that may contain nested blocks.
  if n == nil: return
  case n.kind
  of nkDecl:
    if n.typ != nil and n.typ.kind == tyFn: return
    acc.add n
    collectDecls(n.declInit, acc)
  of nkBlock, nkProgram:
    for s in n.stmts: collectDecls(s, acc)
  of nkIf:
    collectDecls(n.ifCond, acc)
    collectDecls(n.ifThen, acc)
    collectDecls(n.ifElse, acc)
  of nkBinOp:
    collectDecls(n.left, acc); collectDecls(n.right, acc)
  of nkUnary:  collectDecls(n.operand, acc)
  of nkAssign: collectDecls(n.assignValue, acc)
  of nkCast:   collectDecls(n.castExpr, acc)
  of nkCall:
    collectDecls(n.callee, acc)
    for a in n.args: collectDecls(a, acc)
  of nkIs:
    collectDecls(n.isValue, acc)
  of nkRet:
    if n.retExpr != nil: collectDecls(n.retExpr, acc)
  of nkDiscard:
    if n.discardExpr != nil: collectDecls(n.discardExpr, acc)
  else: discard



proc hasBreak(n: Node): bool =
  ## <NOTE>#137: does this loop body contain a `break` that targets
  ## the current loop? Nested `while` owns its own break, do not
  ## descend.
  if n == nil: return false
  case n.kind
  of nkBreak: return true
  of nkWhile: return false
  of nkBlock, nkProgram:
    for s in n.stmts:
      if hasBreak(s): return true
    return false
  of nkIf:
    return hasBreak(n.ifThen) or hasBreak(n.ifElse)
  else: return false

proc hoistAllocas(c: var CodegenCtx, root: Node) =

  ## Emit alloca for every collected nkDecl into the current basic block.
  ## Caller must position the builder at the function entry block and
  ## populate c.declSlots fresh (initTable) before this call.
  var decls: seq[Node] = @[]
  collectDecls(root, decls)
  for d in decls:
    let kind = d.typ.kind
    let llvmTy = llvmIntType(c, kind)
    let slot = LLVMBuildAlloca(c.builder, llvmTy, d.declName.cstring)
    c.declSlots[d] = slot

proc isBuiltinPrint(c: CodegenCtx, n: Node): bool =

  ## <NOTE>#106: a call is a builtin print iff the callee is the ident
  ## `print` AND no user `@print` function exists in the module. User
  ## shadowing wins: codegen calls their `@print` instead.
  n.kind == nkCall and n.callee.kind == nkIdent and
    n.callee.identName == "print" and
    LLVMGetNamedFunction(c.module, "print".cstring) == nil

proc emitExpr(c: var CodegenCtx, n: Node): LLVMValueRef =
  case n.kind
  of nkInt:
    LLVMConstInt(c.i64, cast[culonglong](n.intVal), 0)
  of nkUnary:
    case n.unop
    of uoNeg:
      # <NOTE>#73: negate at the result width. iLit operands are
      # emitted as constants at that width; concrete operands coerce.
      let targetKind = nodeKindOr(n, tyI64)
      let val = emitOperand(c, n.operand, targetKind)
      LLVMBuildNeg(c.builder, val, "neg")
  of nkBinOp:
    case n.op
    of boAdd, boSub, boMul, boDiv, boMod:
      let targetKind = nodeKindOr(n, tyI64)
      let lhs = emitOperand(c, n.left, targetKind)
      let rhs = emitOperand(c, n.right, targetKind)
      let signed = kindSigned(targetKind)
      case n.op
      of boAdd: LLVMBuildAdd(c.builder, lhs, rhs, "add")
      of boSub: LLVMBuildSub(c.builder, lhs, rhs, "sub")
      of boMul: LLVMBuildMul(c.builder, lhs, rhs, "mul")
      of boDiv:
        if signed: LLVMBuildSDiv(c.builder, lhs, rhs, "div")
        else: LLVMBuildUDiv(c.builder, lhs, rhs, "div")
      of boMod:
        if signed: LLVMBuildSRem(c.builder, lhs, rhs, "rem")
        else: LLVMBuildURem(c.builder, lhs, rhs, "rem")
      else: raise newException(ValueError, "unreachable")
    of boEq, boNe, boLt, boLe, boGt, boGe:
      # <NOTE>#43: comparisons operate on a common representation.
      let lIsBool = n.left.typ != nil and n.left.typ.kind == tyBool
      let rIsBool = n.right.typ != nil and n.right.typ.kind == tyBool
      if lIsBool or rIsBool:
        var lhs: LLVMValueRef
        var rhs: LLVMValueRef
        if lIsBool: lhs = emitExpr(c, n.left)
        else: lhs = toBool(c, emitExpr(c, n.left))
        if rIsBool: rhs = emitExpr(c, n.right)
        else: rhs = toBool(c, emitExpr(c, n.right))
        LLVMBuildICmp(c.builder, cmpPredicate(n.op, tyBool), lhs, rhs, "cmp")
      else:
        let targetKind =
          if n.left.typ == nil or n.right.typ == nil: tyI64
          else: commonKindFor(n.left.typ, n.right.typ)
        let lhs = emitOperand(c, n.left, targetKind)
        let rhs = emitOperand(c, n.right, targetKind)
        LLVMBuildICmp(c.builder, cmpPredicate(n.op, targetKind), lhs, rhs, "cmp")
  of nkCall:
    if isBuiltinPrint(c, n):
      raise newException(ValueError,
        "codegen: builtin print used in value position (sema should reject)")
    # <NOTE>#91: callee is nkIdent (fn-as-value is out of scope in v1).
    # Args are coerced to each parameter's kind; ret type is n.typ.
    if n.callee.kind != nkIdent:
      raise newException(ValueError,
        "codegen: call on non-ident not supported yet")
    let fnName = n.callee.identName
    let fnVal = LLVMGetNamedFunction(c.module, fnName.cstring)
    if fnVal == nil:
      raise newException(ValueError,
        "codegen: unknown function: " & fnName)
    if n.callee.typ == nil or n.callee.typ.kind != tyFn:
      raise newException(ValueError,
        "codegen: call callee without tyFn type")
    let fnT = n.callee.typ
    var argVals: seq[LLVMValueRef] = @[]
    for i, a in n.args:
      if fnT.fnParamsMut[i] == muMutable:
        # <NOTE>#99: sema guarantees a.kind == nkIdent and mutable.
        # Pass the caller's alloca ptr.
        let slot = c.lookupVar(a.identName)
        if slot == nil:
          raise newException(ValueError,
            "codegen: mutable arg without slot: " & a.identName)
        argVals.add slot
      else:
        argVals.add emitOperand(c, a, fnT.fnParams[i].kind)
    let llvmFnTy = fnLLVMType(c, fnT)
    if argVals.len == 0:
      LLVMBuildCall2(c.builder, llvmFnTy, fnVal, nil, 0, "call")
    else:
      LLVMBuildCall2(c.builder, llvmFnTy, fnVal, addr argVals[0],
                     cuint(argVals.len), "call")

  of nkAssign:
    # <NOTE>#108: assignment as an expression. Store value, return the
    # assigned value. Mutability is a sema concern; codegen trusts it.
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
      if n.assignValue.typ.kind != n.typ.kind:
        raise newException(ValueError,
          "codegen: mismatched assign type not supported yet (7d-2): " &
          $n.assignValue.typ.kind & " -> " & $n.typ.kind)
    discard LLVMBuildStore(c.builder, val, slot)
    val
  of nkWhile:
    emitWhileExpr(c, n)
  of nkContinue:
    raise newException(ValueError,
      "codegen: continue in value position (sema should reject)")
  of nkCast:
    # <NOTE>#76: cast dispatch on (source kind, target kind). iLit is


    # folded at the target width, no IR instruction emitted. Concrete
    # Int<->Int uses coerceInt (trunc/sext/zext by source signedness).
    # Int<->Bool uses icmp-ne-zero / zext.
    doAssert n.typ != nil, "codegen: cast without sema type"
    let srcKind = nodeKindOr(n.castExpr, tyI64)
    let targetKind = n.typ.kind
    if srcKind == tyILit:
      let v = n.castExpr.typ.value
      if targetKind == tyBool:
        return LLVMConstInt(c.i1, culonglong(if v != 0: 1 else: 0), 0)
      # Int target: emit at target width.
      return LLVMConstInt(llvmIntType(c, targetKind),
                          cast[culonglong](v), 0)
    let v = emitExpr(c, n.castExpr)
    if srcKind == tyBool and targetKind == tyBool:
      return v
    if srcKind == tyBool:
      # Bool -> Int: zext i1 to iN.
      let toTy = llvmIntType(c, targetKind)
      return LLVMBuildZExt(c.builder, v, toTy, "bool_zext")
    if targetKind == tyBool:
      # Int -> Bool: compare to zero, produces i1.
      let srcTy = llvmIntType(c, srcKind)
      return LLVMBuildICmp(c.builder, LLVMIntNE, v,
                           LLVMConstInt(srcTy, 0, 0), "int_to_bool")
    # Int -> Int.
    coerceInt(c, v, srcKind, targetKind)
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

proc emitOperand(c: var CodegenCtx, n: Node,
                  targetKind: TypeKind): LLVMValueRef =
  # <NOTE>#74: iLit operands are emitted directly at the target width
  # (sema already folded the value). Concrete operands emit at their
  # own width, then coerce.
  # <NOTE>#144: iLit target means "no width context" (e.g. discard 1+2,
  # where the folded 3 goes nowhere). Default to i64.
  let tk = if targetKind == tyILit: tyI64 else: targetKind
  if n.typ != nil and n.typ.kind == tyILit:
    return LLVMConstInt(llvmIntType(c, tk),
                        cast[culonglong](n.typ.value), 0)

  let v = emitExpr(c, n)
  if n.typ == nil: return v  # defensive; sema should have set typ
  coerceInt(c, v, n.typ.kind, targetKind)

proc emitStmt(c: var CodegenCtx, n: Node): LLVMValueRef =
  ## Emits one statement. Returns the value expression if n is a value
  ## expr (for main's return), nil for declarative statements.
  case n.kind
  of nkDecl:
    # <NOTE>#82: fn decls are emitted by emitFn (pass 1 of emitModule),
    # not as statements. Return nil here.
    if n.typ != nil and n.typ.kind == tyFn:
      return nil
    doAssert n.typ != nil, "codegen: decl without sema type"
    let declKind = n.typ.kind
    let llvmTy = llvmIntType(c, declKind)
    # <NOTE>#125: alloca already emitted in the entry block by
    # hoistAllocas. Look up by AST node; only create locally if not
    # found (test fixtures that build nkDecl by hand).
    var slot = c.declSlots.getOrDefault(n)
    if slot == nil:
      slot = LLVMBuildAlloca(c.builder, llvmTy, n.declName.cstring)
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
      if n.declInit.typ != nil and
         n.declInit.typ.kind != n.typ.kind:
        raise newException(ValueError,
          "codegen: mismatched init type not supported yet (7d-2): " &
          $n.declInit.typ.kind & " -> " & $n.typ.kind)
    discard LLVMBuildStore(c.builder, initVal, slot)
    nil
  of nkAssign:
    # <NOTE>#108: emitExpr(nkAssign) does the store and returns the
    # value; as a statement the value is discarded.
    discard emitExpr(c, n)
    nil
  of nkInt, nkIdent, nkUnary, nkBinOp, nkCast:
    emitExpr(c, n)
  of nkCall:
    if isBuiltinPrint(c, n):
      ensurePrintf(c)
      let x = emitOperand(c, n.args[0], tyI64)
      var args: array[2, LLVMValueRef] = [c.printfFmt, x]
      discard LLVMBuildCall2(c.builder, c.printfTy, c.printfFn,
                             addr args[0], 2, "")
      nil
    else:
      let v = emitExpr(c, n)
      # <NOTE>#119: a nul-returning call as a statement has no value.
      if n.typ != nil and n.typ.kind == tyNul: nil else: v

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
      # <NOTE>#113: statements after a terminal statement are dead;
      # stop emitting (LLVM would reject the dead code otherwise).
      if isTerminal(s): break
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
    # <NOTE>#115: all-terminal if (both branches ret) needs no merge
    # block; LLVM rejects an empty unterminated block. One-terminal
    # branches (e.g. if c; ret 1) still fall through via merge.
    let allTerm = isTerminal(n)
    let hasElse = n.ifElse != nil
    let thenBB = LLVMCreateBasicBlockInContext(c.ctx, "then")
    var elseBB: LLVMBasicBlockRef = nil
    var mergeBB: LLVMBasicBlockRef = nil
    if hasElse:
      elseBB = LLVMCreateBasicBlockInContext(c.ctx, "else")
    if not allTerm:
      mergeBB = LLVMCreateBasicBlockInContext(c.ctx, "merge")
    let elseTarget = if hasElse: elseBB else: mergeBB
    LLVMAppendExistingBasicBlock(c.mainFn, thenBB)
    if hasElse:
      LLVMAppendExistingBasicBlock(c.mainFn, elseBB)
    if mergeBB != nil:
      LLVMAppendExistingBasicBlock(c.mainFn, mergeBB)
    discard LLVMBuildCondBr(c.builder, cond, thenBB, elseTarget)
    LLVMPositionBuilderAtEnd(c.builder, thenBB)
    discard emitStmt(c, n.ifThen)
    if not isTerminal(n.ifThen) and mergeBB != nil:
      discard LLVMBuildBr(c.builder, mergeBB)
    if hasElse:
      LLVMPositionBuilderAtEnd(c.builder, elseBB)
      discard emitStmt(c, n.ifElse)
      if not isTerminal(n.ifElse) and mergeBB != nil:
        discard LLVMBuildBr(c.builder, mergeBB)
    if mergeBB != nil:
      LLVMPositionBuilderAtEnd(c.builder, mergeBB)
    nil
  of nkWhile:
    return emitWhileExpr(c, n)

  of nkBreak:
    if c.loopExits.len == 0:
      raise newException(ValueError,
        "codegen: break outside loop (sema should reject)")
    discard LLVMBuildBr(c.builder, c.loopExits[^1])
    nil
  of nkContinue:
    if c.loopContinues.len == 0:
      raise newException(ValueError,
        "codegen: continue outside loop (sema should reject)")
    discard LLVMBuildBr(c.builder, c.loopContinues[^1])
    nil
  of nkDiscard:
    # <NOTE>#143: discard evaluates expr for effect and returns nil.
    if n.discardExpr != nil:
      discard emitExpr(c, n.discardExpr)
    nil


  of nkRet:
    # <NOTE>#114: bare `ret` returns the default of the current fn's

    # return kind (0 for ints, false for Bool).
    # <NOTE>#120: Nul-returning functions emit `ret void`.
    if c.curFnRetKind == tyNul:
      discard LLVMBuildRetVoid(c.builder)
    else:
      let v =
        if n.retExpr != nil: emitOperand(c, n.retExpr, c.curFnRetKind)
        elif c.curFnRetKind == tyBool:
          LLVMConstInt(c.i1, 0, 0)
        else:
          LLVMConstInt(llvmIntType(c, c.curFnRetKind), 0, 0)
      discard LLVMBuildRet(c.builder, v)
    nil


  else:
    raise newException(ValueError,
      "codegen: unsupported statement: " & $n.kind)


proc emitWhileExpr(c: var CodegenCtx, n: Node): LLVMValueRef =
  # <NOTE>#139: while returns Bool. true if the loop exited via break,
  # false if the condition became false.
  let brk = hasBreak(n.whileBody)
  let condBB = LLVMCreateBasicBlockInContext(c.ctx, "while.cond")
  let bodyBB = LLVMCreateBasicBlockInContext(c.ctx, "while.body")
  let exitBB = LLVMCreateBasicBlockInContext(c.ctx, "while.exit")
  var breakBB: LLVMBasicBlockRef = nil
  if brk:
    breakBB = LLVMCreateBasicBlockInContext(c.ctx, "while.break")
  LLVMAppendExistingBasicBlock(c.mainFn, condBB)
  LLVMAppendExistingBasicBlock(c.mainFn, bodyBB)
  if brk:
    LLVMAppendExistingBasicBlock(c.mainFn, breakBB)
  LLVMAppendExistingBasicBlock(c.mainFn, exitBB)
  discard LLVMBuildBr(c.builder, condBB)
  LLVMPositionBuilderAtEnd(c.builder, condBB)
  var cond = emitExpr(c, n.whileCond)
  let condIsBool = n.whileCond.typ != nil and n.whileCond.typ.kind == tyBool
  if not condIsBool:
    cond = toBool(c, cond)
  discard LLVMBuildCondBr(c.builder, cond, bodyBB, exitBB)
  c.loopExits.add(if brk: breakBB else: exitBB)
  c.loopContinues.add condBB
  LLVMPositionBuilderAtEnd(c.builder, bodyBB)
  discard emitStmt(c, n.whileBody)
  c.loopContinues.setLen(c.loopContinues.len - 1)
  c.loopExits.setLen(c.loopExits.len - 1)

  if not isTerminal(n.whileBody):
    discard LLVMBuildBr(c.builder, condBB)
  if brk:
    LLVMPositionBuilderAtEnd(c.builder, breakBB)
    discard LLVMBuildBr(c.builder, exitBB)
  LLVMPositionBuilderAtEnd(c.builder, exitBB)
  if brk:
    let phi = LLVMBuildPhi(c.builder, c.i1, "while.result")
    var vals: array[2, LLVMValueRef]
    var blks: array[2, LLVMBasicBlockRef]
    vals[0] = LLVMConstInt(c.i1, 0, 0); blks[0] = condBB
    vals[1] = LLVMConstInt(c.i1, 1, 0); blks[1] = breakBB
    LLVMAddIncoming(phi, addr vals[0], addr blks[0], 2)
    phi
  else:
    LLVMConstInt(c.i1, 0, 0)

proc fnLLVMType(c: CodegenCtx, fnT: LidwType): LLVMTypeRef =

  # <NOTE>#97: mutable params are passed as `ptr`. Caller takes address
  # of its alloca; callee writes through the pointer. Immutable params
  # stay by-value.
  var paramTys: seq[LLVMTypeRef] = @[]
  for i, pt in fnT.fnParams:
    if fnT.fnParamsMut[i] == muMutable:
      paramTys.add LLVMPointerTypeInContext(c.ctx, 0)
    else:
      paramTys.add llvmIntType(c, pt.kind)
  let retTy =
    if fnT.fnRet.kind == tyNul: LLVMVoidTypeInContext(c.ctx)
    else: llvmIntType(c, fnT.fnRet.kind)
  if paramTys.len == 0:
    LLVMFunctionType(retTy, nil, 0, 0)
  else:
    LLVMFunctionType(retTy, addr paramTys[0], cuint(paramTys.len), 0)


proc emitFnBody(c: var CodegenCtx, decl: Node) =
  ## <NOTE>#92: params are bound through alloca+store so they behave
  ## like local vars inside the body (uniform with let). Params are
  ## immutable in sema; Fa.7 will honor `$` mutability.
  let fnVal = LLVMGetNamedFunction(c.module, decl.declName.cstring)
  if fnVal == nil:
    raise newException(ValueError,
      "codegen: fn not pre-registered: " & decl.declName)
  let entry = LLVMAppendBasicBlockInContext(c.ctx, fnVal, "entry")
  LLVMPositionBuilderAtEnd(c.builder, entry)
  let savedMain = c.mainFn
  let savedRetKind = c.curFnRetKind
  let savedSlots = c.declSlots
  c.mainFn = fnVal
  c.curFnRetKind = decl.typ.fnRet.kind
  c.declSlots = initTable[Node, LLVMValueRef]()
  # <NOTE>#126: hoist all local allocas into entry before params/body.
  hoistAllocas(c, decl.declInit)
  LLVMPositionBuilderAtEnd(c.builder, entry)
  c.scopes.add initTable[string, LLVMValueRef]()
  c.varTypes.add initTable[string, LLVMTypeRef]()
  for i, p in decl.declTypeNode.fnParams:


    let ty = llvmIntType(c, decl.typ.fnParams[i].kind)
    let paramVal = LLVMGetParam(fnVal, cuint(i))
    if p.paramMut == muMutable:
      # <NOTE>#98: mutable param arrives as `ptr iN`. Bind it as-is;
      # loads/stores go through the pointer to caller's alloca.
      if p.paramName.len > 0:
        c.defineVar(p.paramName, paramVal, ty)
    else:
      let nameC = if p.paramName.len > 0: p.paramName.cstring else: "arg".cstring
      let slot = LLVMBuildAlloca(c.builder, ty, nameC)
      discard LLVMBuildStore(c.builder, paramVal, slot)
      if p.paramName.len > 0:
        c.defineVar(p.paramName, slot, ty)
  # <NOTE>#116: body handling depends on shape:
  #  - terminal body (nkRet, or if with both branches ret): emit as
  #    statement, it already ret'd; do not append.
  #  - nul body (statement body): emit as statement, then implicit ret
  #    default of fn's return kind (or ret void for Nul fns).
  #  - value body: emit as expression, ret the value.
  if isTerminal(decl.declInit):
    discard emitStmt(c, decl.declInit)
  elif decl.declInit.typ != nil and decl.declInit.typ.kind == tyNul:
    discard emitStmt(c, decl.declInit)
    if decl.typ.fnRet.kind == tyNul:
      discard LLVMBuildRetVoid(c.builder)
    else:
      let defaultVal =
        if decl.typ.fnRet.kind == tyBool: LLVMConstInt(c.i1, 0, 0)
        else: LLVMConstInt(llvmIntType(c, decl.typ.fnRet.kind), 0, 0)
      discard LLVMBuildRet(c.builder, defaultVal)
  else:
    let bodyVal = emitExpr(c, decl.declInit)
    discard LLVMBuildRet(c.builder, bodyVal)

  c.scopes.setLen(c.scopes.len - 1)
  c.varTypes.setLen(c.varTypes.len - 1)
  c.curFnRetKind = savedRetKind
  c.declSlots = savedSlots
  c.mainFn = savedMain



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
  let mainTy = LLVMFunctionType(i64, nil, 0, 0)
  let mainFn = LLVMAddFunction(llmod, "main", mainTy)
  let mainEntry = LLVMAppendBasicBlockInContext(ctx, mainFn, "entry")

  var c = CodegenCtx(ctx: ctx, module: llmod, builder: builder,
                     mainFn: mainFn, i64: i64, i1: i1,
                     curFnRetKind: tyI64,
                     declSlots: initTable[Node, LLVMValueRef](),
                     scopes: @[initTable[string, LLVMValueRef]()],
                     varTypes: @[initTable[string, LLVMTypeRef]()])



  # <NOTE>#93: three passes. 1: declare all fns. 2: emit fn bodies.
  # 3: emit main body. LLVM reorders definitions as it likes.
  if program.kind == nkProgram:
    for stmt in program.stmts:
      if stmt.kind == nkDecl and stmt.typ != nil and stmt.typ.kind == tyFn:
        let llvmFnTy = fnLLVMType(c, stmt.typ)
        discard LLVMAddFunction(llmod, stmt.declName.cstring, llvmFnTy)
    for stmt in program.stmts:
      if stmt.kind == nkDecl and stmt.typ != nil and stmt.typ.kind == tyFn:
        emitFnBody(c, stmt)

  LLVMPositionBuilderAtEnd(builder, mainEntry)
  # <NOTE>#127: hoist all main-scope allocas into mainEntry before
  # emitting the body.
  if program.kind == nkProgram:
    hoistAllocas(c, program)
    LLVMPositionBuilderAtEnd(builder, mainEntry)
  var retVal: LLVMValueRef = nil
  var retType: LidwType = nil
  if program.kind == nkProgram:
    for stmt in program.stmts:

      if stmt.kind == nkDecl and stmt.typ != nil and stmt.typ.kind == tyFn:
        continue
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
