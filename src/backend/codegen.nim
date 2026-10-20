# Codegen: LIDW AST -> LLVM IR text.

import std/[tables, hashes]
import ../version
import ../parser/ast


# <NOTE>#128: Node is a ref; pointer identity is the right key for
# per-declaration alloca slots (shadowing creates distinct nodes).
proc hash(n: Node): Hash = hash(cast[pointer](n))

import ../types
import ./llvm_c

type
  # <NOTE>#219: per-loop bookkeeping. `breakBB` collects every `break`
  # for the current loop; for value loops it carries a phi of the
  # break values, for Bool loops it just `br exit` with `true`.
  LoopBreak = tuple[val: LLVMValueRef, bb: LLVMBasicBlockRef]

  LoopFrame = object
    breakBB: LLVMBasicBlockRef  ## nil if the loop has no breaks
    exitBB: LLVMBasicBlockRef
    continueBB: LLVMBasicBlockRef
    isValueLoop: bool
    valueLLVMType: LLVMTypeRef
    defaultValue: LLVMValueRef
    breakIncoming: seq[LoopBreak]

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
    # <NOTE>#173: llvm.trap is declared lazily on first panic.
    trapFn: LLVMValueRef

    curFnRetKind: TypeKind  ## ret kind of the fn whose body is emitted
    # <NOTE>#182: overflow checks on signed `+ - *`. true by default.
    overflowChecks: bool
    # <NOTE>#183: cache for llvm.<op>.with.overflow.<iN> declarations.
    intrinsics: Table[string, tuple[fn: LLVMValueRef, fnTy: LLVMTypeRef]]

    # <NOTE>#219: innermost last. Replaces loopExits/loopContinues
    # with a per-loop frame that carries value-loop state.
    loopStack: seq[LoopFrame]


    # <NOTE>#148: DI is set up in D.1a (DIFile + DICompileUnit). D.1b
    # will add DILocations on instructions, D.1c DISubprograms, D.1d
    # dbg.declare for locals.
    di: LLVMDIBuilderRef
    diFile: LLVMMetadataRef
    diCU: LLVMMetadataRef
    diScope: seq[LLVMMetadataRef]
      ## <NOTE>#153: CU -> SUBPROGRAM stack. Top is current scope for
      ## DILocation / DISubprogram creation.
    diBasicTypes: Table[TypeKind, LLVMMetadataRef]
    sourceFile: string

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

proc llvmFloatType(c: CodegenCtx, kind: TypeKind): LLVMTypeRef =
  case kind
  of tyF32: LLVMFloatTypeInContext(c.ctx)
  of tyF64: LLVMDoubleTypeInContext(c.ctx)
  else:
    raise newException(AssertionDefect,
      "llvmFloatType: not a float kind: " & $kind)

proc defaultValueOf(c: CodegenCtx, kind: TypeKind): LLVMValueRef =
  # <NOTE>#220: default value for a value-loop's cond-false fallthrough
  # and for bare `break` in a value loop.
  if kind in FloatKinds:
    LLVMConstReal(llvmFloatType(c, kind), cdouble(0.0))
  elif kind == tyBool:
    LLVMConstInt(c.i1, 0, 0)
  else:
    LLVMConstInt(llvmIntType(c, kind), 0, 0)

proc llvmTypeOf(c: CodegenCtx, kind: TypeKind): LLVMTypeRef =

  ## <NOTE>#205: unified: Float kinds -> llvmFloatType, everything
  ## else (Int, Bool, tyILit-as-i64 fallback) -> llvmIntType. Use this
  ## in alloca/store/load for declarations; callers that need strict
  ## int-only still call llvmIntType directly.
  if kind in FloatKinds: llvmFloatType(c, kind)
  else: llvmIntType(c, kind)


proc llvmIntType(c: CodegenCtx, kind: TypeKind): LLVMTypeRef =

  ## <NOTE>#64: LLVM has one iN per width; signedness matters only in
  ## operations (sdiv/udiv, icmp slt/ult), not in the type itself.
  case kind
  of tyI8, tyU8:   LLVMIntTypeInContext(c.ctx, 8)
  of tyI16, tyU16: LLVMIntTypeInContext(c.ctx, 16)
  of tyI32, tyU32: LLVMIntTypeInContext(c.ctx, 32)
  of tyI64, tyU64: c.i64
  of tyBool:       c.i1
  of tyF32, tyF64, tyFLit:
    raise newException(ValueError,
      "codegen: float type not implemented yet (F.5)")
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
proc diSubprogram(c: var CodegenCtx, name: string, line: int,
                  fnT: LidwType): LLVMMetadataRef
proc setLoc(c: var CodegenCtx, n: Node)
proc blockTerminated(c: CodegenCtx): bool
proc diBasicType(c: var CodegenCtx, k: TypeKind): LLVMMetadataRef
proc diIntKind(k: TypeKind): tuple[name: string, bits: int, enc: cint]


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



proc hasBreakExpr(n: Node): bool =
  ## <NOTE>#218: does this loop body contain a `break expr`? Used to
  ## reject value-loops in codegen until L.5c.
  if n == nil: return false
  case n.kind
  of nkBreak: n.breakExpr != nil
  of nkWhile: false
  of nkBlock, nkProgram:
    for s in n.stmts:
      if hasBreakExpr(s): return true
    false
  of nkIf: hasBreakExpr(n.ifThen) or hasBreakExpr(n.ifElse)
  else: false

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
    let llvmTy = llvmTypeOf(c, kind)
    let slot = LLVMBuildAlloca(c.builder, llvmTy, d.declName.cstring)
    c.declSlots[d] = slot


proc ensureTrap(c: var CodegenCtx) =
  if c.trapFn != nil: return
  let voidTy = LLVMVoidTypeInContext(c.ctx)
  let fnTy = LLVMFunctionType(voidTy, nil, 0, 0)
  c.trapFn = LLVMAddFunction(c.module, "llvm.trap", fnTy)

proc emitTrap(c: var CodegenCtx) =
  # <NOTE>#184: emit llvm.trap + unreachable. Used by builtin panic and
  # by overflow-check paths.
  ensureTrap(c)
  let voidTy = LLVMVoidTypeInContext(c.ctx)
  let fnTy = LLVMFunctionType(voidTy, nil, 0, 0)
  discard LLVMBuildCall2(c.builder, fnTy, c.trapFn, nil, 0, "")
  discard LLVMBuildUnreachable(c.builder)

proc ensureArithOf(c: var CodegenCtx, kind: TypeKind, op: BinOp):
    tuple[fn: LLVMValueRef, fnTy: LLVMTypeRef] =
  # <NOTE>#185: declare `llvm.<sadd|ssub|smul>.with.overflow.<iN>` on
  # first use. LLVM verifies intrinsics by name + signature.
  let opName = case op
    of boAdd: "sadd"
    of boSub: "ssub"
    of boMul: "smul"
    else:
      raise newException(AssertionDefect,
        "ensureArithOf: not add/sub/mul: " & opStr(op))
  let kindName = case kind
    of tyI8:  "i8"
    of tyI16: "i16"
    of tyI32: "i32"
    of tyI64: "i64"
    else:
      raise newException(AssertionDefect,
        "ensureArithOf: not signed int: " & $kind)
  let name = "llvm." & opName & ".with.overflow." & kindName
  if c.intrinsics.hasKey(name): return c.intrinsics[name]
  let elTy = llvmIntType(c, kind)
  var elems: array[2, LLVMTypeRef] = [elTy, c.i1]
  let structTy = LLVMStructTypeInContext(c.ctx, addr elems[0], 2, 0)
  var params: array[2, LLVMTypeRef] = [elTy, elTy]

  let fnTy = LLVMFunctionType(structTy, addr params[0], 2, 0)
  let fn = LLVMAddFunction(c.module, name.cstring, fnTy)
  let entry = (fn, fnTy)
  c.intrinsics[name] = entry
  entry

proc emitDivChecked(c: var CodegenCtx, n: Node, kind: TypeKind,
                    lhs, rhs: LLVMValueRef, isRem: bool): LLVMValueRef =
  # <NOTE>#187: div/mod checks:
  #  - rhs == 0 → panic (always, signed and unsigned)
  #  - signed only: lhs == INT_MIN and rhs == -1 → panic. LLVM sdiv/srem
  #    is UB on this input.
  let elTy = llvmIntType(c, kind)
  let zero = LLVMConstInt(elTy, 0, 0)
  let isZero = LLVMBuildICmp(c.builder, LLVMIntEQ, rhs, zero, "div.zero")
  let panic1BB = LLVMCreateBasicBlockInContext(c.ctx, "div.panic1")
  let ok1BB = LLVMCreateBasicBlockInContext(c.ctx, "div.ok1")
  LLVMAppendExistingBasicBlock(c.mainFn, panic1BB)
  LLVMAppendExistingBasicBlock(c.mainFn, ok1BB)
  discard LLVMBuildCondBr(c.builder, isZero, panic1BB, ok1BB)
  LLVMPositionBuilderAtEnd(c.builder, panic1BB)
  setLoc(c, n)
  emitTrap(c)
  LLVMPositionBuilderAtEnd(c.builder, ok1BB)
  let signed = kindSigned(kind)
  var safeLhs = lhs
  var safeRhs = rhs
  if signed:
    let minVal = LLVMConstInt(elTy, cast[culonglong](low(int64)), 0)
    let negOne = LLVMConstInt(elTy, cast[culonglong](-1), 0)
    let isMin = LLVMBuildICmp(c.builder, LLVMIntEQ, lhs, minVal, "div.min")
    let isNeg1 = LLVMBuildICmp(c.builder, LLVMIntEQ, rhs, negOne, "div.neg1")
    let isBad = LLVMBuildAnd(c.builder, isMin, isNeg1, "div.bad")
    let panic2BB = LLVMCreateBasicBlockInContext(c.ctx, "div.panic2")
    let ok2BB = LLVMCreateBasicBlockInContext(c.ctx, "div.ok2")
    LLVMAppendExistingBasicBlock(c.mainFn, panic2BB)
    LLVMAppendExistingBasicBlock(c.mainFn, ok2BB)
    discard LLVMBuildCondBr(c.builder, isBad, panic2BB, ok2BB)
    LLVMPositionBuilderAtEnd(c.builder, panic2BB)
    setLoc(c, n)
    emitTrap(c)
    LLVMPositionBuilderAtEnd(c.builder, ok2BB)
  if isRem:
    if signed: LLVMBuildSRem(c.builder, safeLhs, safeRhs, "rem")
    else: LLVMBuildURem(c.builder, safeLhs, safeRhs, "rem")
  else:
    if signed: LLVMBuildSDiv(c.builder, safeLhs, safeRhs, "div")
    else: LLVMBuildUDiv(c.builder, safeLhs, safeRhs, "div")

proc emitSignedArithOf(c: var CodegenCtx, n: Node, kind: TypeKind,
                       lhs, rhs: LLVMValueRef): LLVMValueRef =

  let (fn, fnTy) = ensureArithOf(c, kind, n.op)
  var args: array[2, LLVMValueRef] = [lhs, rhs]
  let pair = LLVMBuildCall2(c.builder, fnTy, fn, addr args[0], 2, "")
  let v = LLVMBuildExtractValue(c.builder, pair, 0, "arith")
  let ofv = LLVMBuildExtractValue(c.builder, pair, 1, "arith.of")
  let panicBB = LLVMCreateBasicBlockInContext(c.ctx, "arith.panic")
  let contBB = LLVMCreateBasicBlockInContext(c.ctx, "arith.cont")
  LLVMAppendExistingBasicBlock(c.mainFn, panicBB)
  LLVMAppendExistingBasicBlock(c.mainFn, contBB)
  discard LLVMBuildCondBr(c.builder, ofv, panicBB, contBB)
  LLVMPositionBuilderAtEnd(c.builder, panicBB)
  setLoc(c, n)
  emitTrap(c)
  LLVMPositionBuilderAtEnd(c.builder, contBB)
  v


proc isBuiltinPanic(c: CodegenCtx, n: Node): bool =
  ## <NOTE>#174: `panic` is the builtin iff the callee is `panic` AND
  ## no user `@panic` exists. Same shadowing rule as print.
  n.kind == nkCall and n.callee.kind == nkIdent and
    n.callee.identName == "panic" and
    LLVMGetNamedFunction(c.module, "panic".cstring) == nil

proc isBuiltinPrint(c: CodegenCtx, n: Node): bool =


  ## <NOTE>#106: a call is a builtin print iff the callee is the ident
  ## `print` AND no user `@print` function exists in the module. User
  ## shadowing wins: codegen calls their `@print` instead.
  n.kind == nkCall and n.callee.kind == nkIdent and
    n.callee.identName == "print" and
    LLVMGetNamedFunction(c.module, "print".cstring) == nil

proc emitExpr(c: var CodegenCtx, n: Node): LLVMValueRef =
  # <NOTE>#159: every instruction gets a !dbg from the node it comes
  # from. Set at entry; recursive calls reset for their own nodes.
  setLoc(c, n)
  case n.kind
  of nkStrLit:
    raise newException(ValueError,
      "codegen: string literal not implemented yet (S.3)")
  of nkFloat:

    # <NOTE>#221: direct nkFloat in expression position (e.g. `break
    # 1.5`). Emit as f64; caller coerces via coerceInt/emitOperand.
    return LLVMConstReal(llvmFloatType(c, tyF64), cdouble(n.floatVal))

  of nkInt:
    LLVMConstInt(c.i64, cast[culonglong](n.intVal), 0)


  of nkUnary:
    case n.unop
    of uoNeg:
      # <NOTE>#73: negate at the result width.
      # <NOTE>#208: float neg uses LLVMBuildFNeg, not LLVMBuildNeg.
      let targetKind = nodeKindOr(n, tyI64)
      let val = emitOperand(c, n.operand, targetKind)
      if targetKind in FloatKinds:
        LLVMBuildFNeg(c.builder, val, "fneg")
      else:
        LLVMBuildNeg(c.builder, val, "neg")

  of nkBinOp:
    case n.op
    of boConcat:
      # <NOTE>#234: Str & Str runtime concat is S.3; sema accepts,
      # codegen not yet.
      raise newException(ValueError,
        "codegen: Str & Str not implemented yet (S.3)")
    of boAdd, boSub, boMul, boDiv, boMod:

      let targetKind = nodeKindOr(n, tyI64)
      let lhs = emitOperand(c, n.left, targetKind)
      let rhs = emitOperand(c, n.right, targetKind)
      if targetKind in FloatKinds:
        # <NOTE>#209: float arithmetic; no overflow/div-by-zero checks
        # (IEEE Inf/NaN). `%` was rejected by sema for floats.
        case n.op
        of boAdd: LLVMBuildFAdd(c.builder, lhs, rhs, "fadd")
        of boSub: LLVMBuildFSub(c.builder, lhs, rhs, "fsub")
        of boMul: LLVMBuildFMul(c.builder, lhs, rhs, "fmul")
        of boDiv: LLVMBuildFDiv(c.builder, lhs, rhs, "fdiv")
        else:
          raise newException(ValueError,
            "codegen: unsupported float binop: " & opStr(n.op))
      else:
        let signed = kindSigned(targetKind)
        case n.op
        of boAdd, boSub, boMul:
          # <NOTE>#186: signed add/sub/mul check for overflow; unsigned
          # is wrap-by-design.
          if signed and c.overflowChecks:
            emitSignedArithOf(c, n, targetKind, lhs, rhs)
          else:
            case n.op
            of boAdd: LLVMBuildAdd(c.builder, lhs, rhs, "add")
            of boSub: LLVMBuildSub(c.builder, lhs, rhs, "sub")
            of boMul: LLVMBuildMul(c.builder, lhs, rhs, "mul")
            else: raise newException(ValueError, "unreachable")
        of boDiv:
          # <NOTE>#188: div/mod always check rhs != 0; signed also
          # checks INT_MIN / -1 (UB in LLVM sdiv/srem).
          if c.overflowChecks:
            emitDivChecked(c, n, targetKind, lhs, rhs, isRem = false)
          else:
            if signed: LLVMBuildSDiv(c.builder, lhs, rhs, "div")
            else: LLVMBuildUDiv(c.builder, lhs, rhs, "div")
        of boMod:
          if c.overflowChecks:
            emitDivChecked(c, n, targetKind, lhs, rhs, isRem = true)
          else:
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
    if isBuiltinPanic(c, n):
      raise newException(ValueError,
        "codegen: builtin panic used in value position (sema should reject)")

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
    # <NOTE>#147: void calls cannot carry a name; LLVM rejects
    # `%x = call void @f()`. Use empty name for Nul-returning calls.
    let callName: cstring =
      if fnT.fnRet.kind == tyNul: "" else: "call"
    let llvmFnTy = fnLLVMType(c, fnT)
    if argVals.len == 0:
      LLVMBuildCall2(c.builder, llvmFnTy, fnVal, nil, 0, callName)
    else:
      LLVMBuildCall2(c.builder, llvmFnTy, fnVal, addr argVals[0],
                     cuint(argVals.len), callName)



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
  of nkDiscard:
    # <NOTE>#146: discard yields Nul. emitExpr must return an
    # LLVMValueRef, so it cannot be called for a value. Sema should
    # have rejected; if we got here, it is a compiler bug.
    raise newException(ValueError,
      "codegen: discard in value position (sema should reject)")
  of nkContinue:
    raise newException(ValueError,
      "codegen: continue in value position (sema should reject)")

  of nkCast:
    # <NOTE>#76: cast dispatch on (source kind, target kind).
    # <NOTE>#203: Float branches. iLit/fLit fold to a constant at
    # target kind; concrete Int<->Float uses sitofp/uitofp/fptosi/
    # fptoui; F32<->F64 uses fpext/fptrunc; Float->Bool uses fcmp une
    # (NaN -> true).
    doAssert n.typ != nil, "codegen: cast without sema type"
    let srcKind = nodeKindOr(n.castExpr, tyI64)
    let targetKind = n.typ.kind
    let targetIsFloat = targetKind in FloatKinds
    let srcIsFloat = srcKind in FloatKinds

    if srcKind == tyILit:
      let v = n.castExpr.typ.value
      if targetKind == tyBool:
        return LLVMConstInt(c.i1, culonglong(if v != 0: 1 else: 0), 0)
      if targetIsFloat:
        return LLVMConstReal(llvmFloatType(c, targetKind), cdouble(float(v)))
      return LLVMConstInt(llvmIntType(c, targetKind),
                          cast[culonglong](v), 0)
    if srcKind == tyFLit:
      let fv = n.castExpr.typ.fValue
      if targetIsFloat:
        return LLVMConstReal(llvmFloatType(c, targetKind), cdouble(fv))
      if targetKind == tyBool:
        let isNZ = (fv != 0.0) or (fv != fv)
        return LLVMConstInt(c.i1, culonglong(if isNZ: 1 else: 0), 0)
      # <NOTE>#204: Nim's int64(float) truncates toward zero (like
      # LLVM fptosi), so `trunc` is not needed.
      return LLVMConstInt(llvmIntType(c, targetKind),
                          cast[culonglong](int64(fv)), 0)


    let v = emitExpr(c, n.castExpr)

    if srcKind == tyBool and targetKind == tyBool:
      return v
    if srcKind == tyBool:
      let toTy = llvmIntType(c, targetKind)
      return LLVMBuildZExt(c.builder, v, toTy, "bool_zext")

    if targetKind == tyBool:
      if srcIsFloat:
        let zero = LLVMConstReal(llvmFloatType(c, srcKind), cdouble(0.0))
        return LLVMBuildFCmp(c.builder, LLVMRealUNE, v, zero, "float_to_bool")
      let srcTy = llvmIntType(c, srcKind)
      return LLVMBuildICmp(c.builder, LLVMIntNE, v,
                           LLVMConstInt(srcTy, 0, 0), "int_to_bool")

    if srcIsFloat and targetIsFloat:
      if srcKind == targetKind: return v
      let toTy = llvmFloatType(c, targetKind)
      if targetKind == tyF32:
        return LLVMBuildFPTrunc(c.builder, v, toTy, "fptrunc")
      else:
        return LLVMBuildFPExt(c.builder, v, toTy, "fpext")
    if srcIsFloat and targetKind in IntKinds:
      let toTy = llvmIntType(c, targetKind)
      if kindSigned(targetKind):
        return LLVMBuildFPToSI(c.builder, v, toTy, "fptosi")
      else:
        return LLVMBuildFPToUI(c.builder, v, toTy, "fptoui")
    if srcKind in IntKinds and targetIsFloat:
      let toTy = llvmFloatType(c, targetKind)
      if kindSigned(srcKind):
        return LLVMBuildSIToFP(c.builder, v, toTy, "sitofp")
      else:
        return LLVMBuildUIToFP(c.builder, v, toTy, "uitofp")

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
    # <NOTE>#181: if branch terminated (panic), no br + no phi incoming.
    let thenTerm = blockTerminated(c)
    if not thenTerm:
      discard LLVMBuildBr(c.builder, mergeBB)
    LLVMPositionBuilderAtEnd(c.builder, elseBB)
    var elseVal: LLVMValueRef
    if n.ifElse != nil:
      elseVal = emitExpr(c, n.ifElse)
      if llvmTy == c.i1 and not (n.ifElse.typ != nil and n.ifElse.typ.kind == tyBool):
        elseVal = toBool(c, elseVal)
    else:
      elseVal = LLVMConstInt(llvmTy, 0, 0)
    let elseTerm = blockTerminated(c)
    if not elseTerm:
      discard LLVMBuildBr(c.builder, mergeBB)
    LLVMPositionBuilderAtEnd(c.builder, mergeBB)
    # <NOTE>#181: phi needs incoming from non-terminated branches only.
    # At least one side is non-terminated (sema rejects all-terminal
    # if in value position? if both terminal, n.typ was nul and we
    # did not enter this path). Keep it simple: phi from both if
    # neither terminated; this path is only reached when at least one
    # side falls through, but a robust phi needs the exact live preds.
    # For now: if a branch terminated, phi has one incoming from the
    # other branch, but that branch also terminates → whole if is
    # terminal. Sema should have marked n.typ = nul then; the guard
    # above prevents entry. Fall back to LLVMValueRef(nil) is unsafe;
    # assume both non-terminated (sema contract).
    if thenTerm or elseTerm:
      raise newException(ValueError,
        "codegen: value-if with terminated branch (sema should reject)")

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
  # <NOTE>#74: literal operands are emitted directly at target kind.
  # Concrete operands emit at own kind, then coerce.
  # <NOTE>#144: iLit target means "no width context" (e.g. discard
  # 1+2); default to i64 for ints.
  # <NOTE>#207: float targets emit LLVMConstReal; concrete float
  # operands coerce by fpext/fptrunc.
  let targetIsFloat = targetKind in FloatKinds
  if n.typ != nil and n.typ.kind == tyILit:
    if targetIsFloat:
      return LLVMConstReal(llvmFloatType(c, targetKind),
                           cdouble(float(n.typ.value)))
    let tk = if targetKind == tyILit: tyI64 else: targetKind
    return LLVMConstInt(llvmIntType(c, tk),
                        cast[culonglong](n.typ.value), 0)
  if n.typ != nil and n.typ.kind == tyFLit:
    if targetIsFloat:
      return LLVMConstReal(llvmFloatType(c, targetKind),
                           cdouble(n.typ.fValue))
    raise newException(ValueError,
      "codegen: fLit operand in non-float target (sema should reject)")

  let v = emitExpr(c, n)
  if n.typ == nil: return v
  if n.typ.kind in FloatKinds:
    if targetIsFloat:
      if n.typ.kind == targetKind: return v
      let toTy = llvmFloatType(c, targetKind)
      if targetKind == tyF32:
        return LLVMBuildFPTrunc(c.builder, v, toTy, "fptrunc")
      else:
        return LLVMBuildFPExt(c.builder, v, toTy, "fpext")
    raise newException(ValueError,
      "codegen: float operand in int target (sema should reject)")
  coerceInt(c, v, n.typ.kind, targetKind)


proc emitStmt(c: var CodegenCtx, n: Node): LLVMValueRef =
  ## Emits one statement. Returns the value expression if n is a value
  ## expr (for main's return), nil for declarative statements.
  setLoc(c, n)
  case n.kind

  of nkDecl:
    # <NOTE>#82: fn decls are emitted by emitFn (pass 1 of emitModule),
    # not as statements. Return nil here.
    if n.typ != nil and n.typ.kind == tyFn:
      return nil
    doAssert n.typ != nil, "codegen: decl without sema type"
    let declKind = n.typ.kind
    let llvmTy = llvmTypeOf(c, declKind)
    # <NOTE>#125: alloca already emitted in the entry block by
    # hoistAllocas. Look up by AST node; only create locally if not
    # found (test fixtures that build nkDecl by hand).
    var slot = c.declSlots.getOrDefault(n)
    if slot == nil:
      slot = LLVMBuildAlloca(c.builder, llvmTy, n.declName.cstring)
    c.defineVar(n.declName, slot, llvmTy)

    let slotIsFloat = declKind in FloatKinds
    var initVal: LLVMValueRef
    if n.declInit == nil:
      if slotIsFloat:
        initVal = LLVMConstReal(llvmTy, cdouble(0.0))
      else:
        initVal = LLVMConstInt(llvmTy, 0, 0)
    elif slotIsFloat and (
         (n.declInit.kind == nkInt) or
         (n.declInit.typ != nil and n.declInit.typ.kind == tyILit)):
      # <NOTE>#229: under a float slot, nkInt and iLit both become
      # LLVMConstReal. Order matters: check slotIsFloat first, else
      # LLVMConstInt(double, ...) produces "store i0".
      let iv =
        if n.declInit.kind == nkInt: n.declInit.intVal
        else: n.declInit.typ.value
      initVal = LLVMConstReal(llvmTy, cdouble(float(iv)))
    elif n.declInit.kind == nkInt:
      initVal = LLVMConstInt(llvmTy,
        cast[culonglong](n.declInit.intVal), 0)
    elif n.declInit.typ != nil and n.declInit.typ.kind == tyILit:
      initVal = LLVMConstInt(llvmTy,
        cast[culonglong](n.declInit.typ.value), 0)

    elif n.declInit.typ != nil and n.declInit.typ.kind == tyFLit:
      # <NOTE>#206: fLit init under concrete Float slot.
      initVal = LLVMConstReal(llvmTy, cdouble(n.declInit.typ.fValue))
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
    # <NOTE>#164: attach a DILocalVariable to the alloca so gdb shows
    # `p x` at the right line. In LLVM 23 this is a DbgRecord, not
    # the old dbg.declare intrinsic.
    if c.di != nil and c.diScope.len > 0 and n.typ != nil and
       n.typ.kind != tyFn and n.typ.kind != tyNul:
      let info = diIntKind(n.typ.kind)
      let varMD = LLVMDIBuilderCreateAutoVariable(c.di,
        c.diScope[^1],
        n.declName.cstring, csize_t(n.declName.len),
        c.diFile,
        cuint(max(n.line, 1)),
        diBasicType(c, n.typ.kind),
        0,        # AlwaysPreserve
        0,        # Flags
        cuint(info.bits))
      let loc = LLVMDIBuilderCreateDebugLocation(c.ctx,
        cuint(max(n.line, 1)), cuint(max(n.col, 1)),
        c.diScope[^1], nil)
      # <NOTE>#165: LLVM 23 rejects `#dbg_declare(..., (null), ...)`;
      # the expression must be a DIExpression, even an empty one.
      let expr = LLVMDIBuilderCreateExpression(c.di, nil, 0)
      discard LLVMDIBuilderInsertDeclareRecordAtEnd(c.di,
        slot, varMD, expr, loc, LLVMGetInsertBlock(c.builder))

    nil
  of nkAssign:

    # <NOTE>#108: emitExpr(nkAssign) does the store and returns the
    # value; as a statement the value is discarded.
    discard emitExpr(c, n)
    nil
  of nkFloat:
    raise newException(ValueError,
      "codegen: float literal not implemented yet (F.5)")
  of nkInt, nkIdent, nkUnary, nkBinOp, nkCast:
    emitExpr(c, n)

  of nkCall:
    if isBuiltinPanic(c, n):
      # <NOTE>#175: panic lowers to llvm.trap + unreachable.
      emitTrap(c)
      nil

    elif isBuiltinPrint(c, n):
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
      # <NOTE>#178: check the block terminator too, because builtin
      # panic emits unreachable without sema knowing.
      if isTerminal(s) or blockTerminated(c): break

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
    # <NOTE>#180: check blockTerminated (panic emits unreachable) too.
    if not isTerminal(n.ifThen) and not blockTerminated(c) and mergeBB != nil:
      discard LLVMBuildBr(c.builder, mergeBB)
    if hasElse:
      LLVMPositionBuilderAtEnd(c.builder, elseBB)
      discard emitStmt(c, n.ifElse)
      if not isTerminal(n.ifElse) and not blockTerminated(c) and mergeBB != nil:
        discard LLVMBuildBr(c.builder, mergeBB)
    if mergeBB != nil:
      LLVMPositionBuilderAtEnd(c.builder, mergeBB)
    nil

  of nkWhile:
    return emitWhileExpr(c, n)

  of nkBreak:
    if c.loopStack.len == 0:
      raise newException(ValueError,
        "codegen: break outside loop (sema should reject)")
    let frame = addr c.loopStack[^1]
    if frame.isValueLoop:
      # <NOTE>#222: compute break value (or default for bare break),
      # record it for the exit phi.
      var v: LLVMValueRef
      if n.breakExpr != nil:
        v = emitExpr(c, n.breakExpr)
      else:
        v = frame.defaultValue
      frame.breakIncoming.add (v, LLVMGetInsertBlock(c.builder))
    if frame.breakBB == nil:
      # Bare Bool loop break — no breakBB (should not happen; hasBreak
      # implies breakBB is set). Defensive fallback to exit.
      discard LLVMBuildBr(c.builder, frame.exitBB)
    else:
      discard LLVMBuildBr(c.builder, frame.breakBB)
    nil
  of nkContinue:
    if c.loopStack.len == 0:
      raise newException(ValueError,
        "codegen: continue outside loop (sema should reject)")
    discard LLVMBuildBr(c.builder, c.loopStack[^1].continueBB)
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
  # <NOTE>#139: while with no `break expr` returns Bool (true=break,
  # false=cond-false). With at least one `break expr` it is a value
  # loop: exit phi returns the break value (or default for bare break
  # / cond-false).
  let isValueLoop = hasBreakExpr(n.whileBody)
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

  var frame = LoopFrame(
    breakBB: breakBB, exitBB: exitBB, continueBB: condBB,
    isValueLoop: isValueLoop, breakIncoming: @[])
  if isValueLoop:
    # <NOTE>#223: sema guarantees n.typ is the concrete value type.
    let kind = nodeKindOr(n, tyI64)
    frame.valueLLVMType = llvmTypeOf(c, kind)
    frame.defaultValue = defaultValueOf(c, kind)
  c.loopStack.add frame

  discard LLVMBuildBr(c.builder, condBB)
  LLVMPositionBuilderAtEnd(c.builder, condBB)
  var cond = emitExpr(c, n.whileCond)
  let condIsBool = n.whileCond.typ != nil and n.whileCond.typ.kind == tyBool
  if not condIsBool:
    cond = toBool(c, cond)
  discard LLVMBuildCondBr(c.builder, cond, bodyBB, exitBB)
  LLVMPositionBuilderAtEnd(c.builder, bodyBB)
  discard emitStmt(c, n.whileBody)

  # <NOTE>#227: `frame` is a local copy; emitStmt(nkBreak) mutates
  # `c.loopStack[^1].breakIncoming`. Copy back so phi gets its values.
  frame = c.loopStack[^1]

  if not blockTerminated(c) and not isTerminal(n.whileBody):
    discard LLVMBuildBr(c.builder, condBB)


  var brkPhi: LLVMValueRef = nil

  if brk:
    LLVMPositionBuilderAtEnd(c.builder, breakBB)
    if isValueLoop:
      # <NOTE>#224: phi at breakBB, one incoming per break site.
      brkPhi = LLVMBuildPhi(c.builder, frame.valueLLVMType, "while.brk")
      let nInc = frame.breakIncoming.len
      if nInc > 0:
        var vals = newSeq[LLVMValueRef](nInc)
        var blks = newSeq[LLVMBasicBlockRef](nInc)
        for i, pair in frame.breakIncoming:
          vals[i] = pair.val
          blks[i] = pair.bb

        LLVMAddIncoming(brkPhi, addr vals[0], addr blks[0], cuint(nInc))
      discard LLVMBuildBr(c.builder, exitBB)
    else:
      discard LLVMBuildBr(c.builder, exitBB)

  LLVMPositionBuilderAtEnd(c.builder, exitBB)

  # Pop frame before emitting phi (breakIncoming already consumed).
  c.loopStack.setLen(c.loopStack.len - 1)

  if isValueLoop:
    # <NOTE>#225: exit phi: [default from cond], [brkPhi from breakBB].
    let exitPhi = LLVMBuildPhi(c.builder, frame.valueLLVMType, "while.result")
    var vals: array[2, LLVMValueRef]
    var blks: array[2, LLVMBasicBlockRef]
    vals[0] = frame.defaultValue; blks[0] = condBB
    if brk:
      vals[1] = brkPhi; blks[1] = breakBB
      LLVMAddIncoming(exitPhi, addr vals[0], addr blks[0], 2)
    else:
      LLVMAddIncoming(exitPhi, addr vals[0], addr blks[0], 1)
    exitPhi

  elif brk:
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
  let fnSP = diSubprogram(c, decl.declName, decl.line, decl.typ)
  LLVMSetSubprogram(fnVal, fnSP)
  c.diScope.add fnSP
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
  # <NOTE>#177: if the body already terminated (panic), do not append
  # another terminator.
  if isTerminal(decl.declInit):
    discard emitStmt(c, decl.declInit)
  elif decl.declInit.typ != nil and decl.declInit.typ.kind == tyNul:
    discard emitStmt(c, decl.declInit)
    if not blockTerminated(c):
      if decl.typ.fnRet.kind == tyNul:
        discard LLVMBuildRetVoid(c.builder)
      else:
        let defaultVal =
          if decl.typ.fnRet.kind == tyBool: LLVMConstInt(c.i1, 0, 0)
          else: LLVMConstInt(llvmIntType(c, decl.typ.fnRet.kind), 0, 0)
        discard LLVMBuildRet(c.builder, defaultVal)
  else:
    let bodyVal = emitExpr(c, decl.declInit)
    if not blockTerminated(c):
      discard LLVMBuildRet(c.builder, bodyVal)


  c.scopes.setLen(c.scopes.len - 1)
  c.varTypes.setLen(c.varTypes.len - 1)
  c.curFnRetKind = savedRetKind
  c.declSlots = savedSlots
  c.mainFn = savedMain
  c.diScope.setLen(c.diScope.len - 1)




proc diIntKind(k: TypeKind): tuple[name: string, bits: int, enc: cint] =
  case k
  of tyI8:  ("i8",  8,  LLVMDWATEsigned)
  of tyU8:  ("u8",  8,  LLVMDWATEunsigned)
  of tyI16: ("i16", 16, LLVMDWATEsigned)
  of tyU16: ("u16", 16, LLVMDWATEunsigned)
  of tyI32: ("i32", 32, LLVMDWATEsigned)
  of tyU32: ("u32", 32, LLVMDWATEunsigned)
  of tyI64: ("i64", 64, LLVMDWATEsigned)
  of tyU64: ("u64", 64, LLVMDWATEunsigned)
  of tyBool: ("Bool", 8, LLVMDWATEboolean)
  of tyILit: ("iLit", 64, LLVMDWATEsigned)
  of tyF32: ("f32", 32, LLVMDWATEfloat)
  of tyF64: ("f64", 64, LLVMDWATEfloat)
  of tyFLit: ("fLit", 64, LLVMDWATEfloat)
  else:
    raise newException(AssertionDefect,
      "diIntKind: not an int/bool/float kind: " & $k)


proc diBasicType(c: var CodegenCtx, k: TypeKind): LLVMMetadataRef =
  if c.diBasicTypes.hasKey(k):
    return c.diBasicTypes[k]
  # <NOTE>#154: iLit is not a real type; map to i64 in DI.
  let info = diIntKind(k)
  let m = LLVMDIBuilderCreateBasicType(c.di,
    info.name.cstring, csize_t(info.name.len),
    culonglong(info.bits), cuint(info.enc), 0)


  c.diBasicTypes[k] = m
  m

proc diSubroutineType(c: var CodegenCtx, fnT: LidwType): LLVMMetadataRef =
  ## <NOTE>#155: D.1b: param DI type is the value type, not `ptr` for
  ## mutable params. `DIDerivedType(pointer)` lands in D.1b fix-up.
  var paramTypes: seq[LLVMMetadataRef] = @[]
  # First element is the return type; nil for void.
  if fnT.fnRet.kind == tyNul:
    paramTypes.add nil
  else:
    paramTypes.add diBasicType(c, fnT.fnRet.kind)
  for pt in fnT.fnParams:
    paramTypes.add diBasicType(c, pt.kind)
  let arr = if paramTypes.len == 0: nil else: addr paramTypes[0]
  LLVMDIBuilderCreateSubroutineType(c.di, c.diFile,
    arr, cuint(paramTypes.len), 0)

proc diSubprogram(c: var CodegenCtx, name: string, line: int,
                  fnT: LidwType): LLVMMetadataRef =
  let subT = diSubroutineType(c, fnT)
  let nameC = name.cstring
  LLVMDIBuilderCreateFunction(c.di,
    c.diCU,                          # scope
    nameC, csize_t(name.len),        # name
    nameC, csize_t(name.len),        # linkage name
    c.diFile,
    cuint(max(line, 1)),
    subT,
    0, 1,                            # isLocalToUnit, isDefinition
    cuint(max(line, 1)),             # scopeLine
    0, 0)                            # flags, isOptimized


proc blockTerminated(c: CodegenCtx): bool =
  ## <NOTE>#176: true if the current basic block already has a
  ## terminator (ret, br, unreachable). Needed because builtin panic
  ## emits `unreachable` directly and sema's isTerminal does not see
  ## it (we deliberately do not teach sema about builtin names).
  let bb = LLVMGetInsertBlock(c.builder)
  if bb == nil: return true
  LLVMGetBasicBlockTerminator(bb) != nil

proc setLoc(c: var CodegenCtx, n: Node) =

  ## <NOTE>#158: attach !dbg to the next emitted instruction(s). Scope
  ## is the innermost DISubprogram (top of c.diScope, which is main
  ## until emitFnBody pushes a fn scope). Line/col from n; line 1 col
  ## 1 fallback if n is nil or has zero.
  if c.di == nil or c.diScope.len == 0: return
  if n == nil: return
  let line = if n.line > 0: cuint(n.line) else: 1.cuint
  let col = if n.col > 0: cuint(n.col) else: 1.cuint
  let scope = c.diScope[^1]
  let loc = LLVMDIBuilderCreateDebugLocation(c.ctx, line, col, scope, nil)
  LLVMSetCurrentDebugLocation2(c.builder, loc)

proc initTarget(llmod: LLVMModuleRef) =
  # <NOTE>#212: portable target setup. Resolve host triple, look up
  # target, create TargetMachine (generic CPU, no features, O0,
  # default reloc/code model), derive data layout from the machine,
  # set both on the module. If the target is not compiled into
  # libLLVM, raise with the LLVM error message instead of emitting a
  # wrong layout.
  let triple = LLVMGetDefaultTargetTriple()
  if triple == nil:
    raise newException(ValueError,
      "codegen: LLVMGetDefaultTargetTriple returned nil")
  let tripleStr = $triple
  LLVMSetTarget(llmod, triple)
  var target: LLVMTargetRef = nil
  var errMsg: cstring = nil
  if LLVMGetTargetFromTriple(triple, addr target, addr errMsg) != 0:
    let msg = if errMsg != nil: $errMsg else: "unknown"
    if errMsg != nil: LLVMDisposeMessage(errMsg)
    LLVMDisposeMessage(triple)
    raise newException(ValueError,
      "codegen: target for " & tripleStr & " not built into LLVM: " & msg)
  # LLVMCodeGenLevelNone=0, LLVMRelocDefault=0, LLVMCodeModelDefault=0.
  let tm = LLVMCreateTargetMachine(target, triple,
                                   "generic".cstring, "".cstring, 0, 0, 0)
  if tm == nil:
    LLVMDisposeMessage(triple)
    raise newException(ValueError,
      "codegen: LLVMCreateTargetMachine failed for " & tripleStr)
  let td = LLVMCreateTargetDataLayout(tm)
  if td != nil:
    let layout = LLVMCopyStringRepOfTargetData(td)
    if layout != nil:
      LLVMSetDataLayout(llmod, layout)
      LLVMDisposeMessage(layout)
    LLVMDisposeTargetData(td)
  LLVMDisposeTargetMachine(tm)
  LLVMDisposeMessage(triple)



proc initDI(c: var CodegenCtx, llmod: LLVMModuleRef) =



  ## <NOTE>#149: minimal DI. DICompileUnit + DIFile at module scope.
  ## No DISubprogram, no DILocation yet — that is D.1b/c.
  # <NOTE>#161: LLVMDIBuilderCreateCompileUnit in LLVM 23 has no
  # DwarfVersion parameter. Without a module flag, IR carries
  # `version: 0` and clang rejects it ("invalid debug version (0)").
  # Set `Dwarf Version = 5` and `Debug Info Version = 3` at module
  # level so clang emits .debug_info.
  # <NOTE>#162: LLVMAddModuleFlag takes LLVMMetadataRef. Wrap the
  # ConstantInt into metadata via LLVMValueAsMetadata; do NOT wrap
  # again in MetadataAsValue (that produces a Value*, which the C API
  # misinterprets as Metadata* and segfaults).
  let i32t = LLVMInt32TypeInContext(c.ctx)
  let dwarfMD = LLVMValueAsMetadata(LLVMConstInt(i32t, 5, 0))
  let infoMD = LLVMValueAsMetadata(LLVMConstInt(i32t, 3, 0))
  LLVMAddModuleFlag(llmod, LLVMModuleFlagBehaviorWarning,
    "Dwarf Version".cstring, 13, dwarfMD)
  LLVMAddModuleFlag(llmod, LLVMModuleFlagBehaviorWarning,
    "Debug Info Version".cstring, 18, infoMD)




  c.di = LLVMCreateDIBuilder(llmod)

  let fname = c.sourceFile
  let dir = "."
  c.diFile = LLVMDIBuilderCreateFile(c.di,
    fname.cstring, csize_t(fname.len),
    dir.cstring, csize_t(dir.len))
  let producer = "lidw " & LidwVersion
  c.diCU = LLVMDIBuilderCreateCompileUnit(c.di,
    LLVMDWARFSourceLanguageC, c.diFile,

    producer.cstring, csize_t(producer.len),
    0,             # isOptimized
    "".cstring, 0, # Flags
    0,             # RuntimeVer
    "".cstring, 0, # SplitName
    LLVMDWARFEmissionKindFull, 0,
    0, 0,          # SplitDebugInlining, DebugInfoForProfiling
    "".cstring, 0, # SysRoot
    "".cstring, 0) # SDK

proc emitModule*(program: Node, sourceFile: string = "<expr>",
                 overflowChecks: bool = true): string =


  ## Lower the program and return textual LLVM IR.
  ## <TODO>#39: temporary semantics — main returns the last value
  ## expression. Replace with real program semantics once `print`/side
  ## effects exist.
  # <NOTE>#169: register host targets before LLVMGetTargetFromTriple.
  # LLVMInitializeAllTargets is `static inline`; call per-family.
  # <NOTE>#211: X86 / AArch64 / ARM / RISCV. Add more families here
  # if "target X not built into LLVM" appears on another host.
  LLVMInitializeX86TargetInfo()
  LLVMInitializeX86Target()
  LLVMInitializeX86TargetMC()
  LLVMInitializeX86AsmPrinter()
  LLVMInitializeAArch64TargetInfo()
  LLVMInitializeAArch64Target()
  LLVMInitializeAArch64TargetMC()
  LLVMInitializeAArch64AsmPrinter()
  LLVMInitializeARMTargetInfo()
  LLVMInitializeARMTarget()
  LLVMInitializeARMTargetMC()
  LLVMInitializeARMAsmPrinter()
  LLVMInitializeRISCVTargetInfo()
  LLVMInitializeRISCVTarget()
  LLVMInitializeRISCVTargetMC()
  LLVMInitializeRISCVAsmPrinter()


  let ctx = LLVMContextCreate()
  defer: LLVMContextDispose(ctx)
  let llmod = LLVMModuleCreateWithNameInContext("lidw", ctx)

  defer: LLVMDisposeModule(llmod)
  let builder = LLVMCreateBuilderInContext(ctx)
  defer: LLVMDisposeBuilder(builder)

  initTarget(llmod)

  let di = LLVMCreateDIBuilder(llmod)
  defer: LLVMDisposeDIBuilder(di)


  let i64 = LLVMInt64TypeInContext(ctx)

  let i1 = LLVMInt1TypeInContext(ctx)
  let mainTy = LLVMFunctionType(i64, nil, 0, 0)
  let mainFn = LLVMAddFunction(llmod, "main", mainTy)
  let mainEntry = LLVMAppendBasicBlockInContext(ctx, mainFn, "entry")

  var c = CodegenCtx(ctx: ctx, module: llmod, builder: builder,
                     mainFn: mainFn, i64: i64, i1: i1,
                     curFnRetKind: tyI64,
                     overflowChecks: overflowChecks,
                     intrinsics: initTable[string, tuple[fn: LLVMValueRef, fnTy: LLVMTypeRef]](),

                     sourceFile: sourceFile,
                     declSlots: initTable[Node, LLVMValueRef](),
                     scopes: @[initTable[string, LLVMValueRef]()],
                     varTypes: @[initTable[string, LLVMTypeRef]()])

  c.di = di
  initDI(c, llmod)
  c.diBasicTypes = initTable[TypeKind, LLVMMetadataRef]()
  c.diScope = @[c.diCU]
  # <NOTE>#156: main DISubprogram. Register before appending the entry
  # basic block so any DILocation inside sees the right scope.
  let mainT = fnType(i64Type(), @[], @[])
  let mainSP = diSubprogram(c, "main", 1, mainT)
  LLVMSetSubprogram(mainFn, mainSP)
  c.diScope.add mainSP





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
  # <NOTE>#166: pass 2 left a stale current debug location (last fn's
  # scope) on the builder. Reset to nil so hoistAllocas' allocas do
  # not inherit a foreign subprogram's scope; LLVM verify rejects
  # `!dbg` from the wrong subprogram.
  LLVMSetCurrentDebugLocation2(builder, nil)
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
    elif retType.kind in FloatKinds:
      # <NOTE>#228: main returns i64; a float-typed last expression is
      # truncated toward zero (fptosi). For `lidw build` this is debug
      # convenience, not language semantics; `print` is the real API.
      retVal = LLVMBuildFPToSI(builder, retVal, i64, "ret_fptosi")

  # <NOTE>#160: setLoc BEFORE the final ret so the ret has main's
  # scope, not the last fn emitted by pass 2 (which left a stale
  # current debug location on the builder).
  # <NOTE>#177: if the body already terminated (e.g. `panic()` as the
  # last statement emitted llvm.trap + unreachable), do not append a
  # second terminator.
  if not blockTerminated(c):
    setLoc(c, if program.kind == nkProgram and program.stmts.len > 0:
                program.stmts[^1] else: nil)
    discard LLVMBuildRet(builder, retVal)



  # <NOTE>#150: finalize DI before verify/print so !llvm.dbg.cu appears
  # in the output. DI without DISubprogram/DILocation is valid.
  LLVMDIBuilderFinalize(c.di)

  var errMsg: cstring = nil
  let verifyOk = LLVMVerifyModule(llmod, ReturnStatus, addr errMsg)

  if verifyOk != 0:
    let msg = if errMsg != nil: $errMsg else: "<no message>"
    if errMsg != nil: LLVMDisposeMessage(errMsg)
    raise newException(ValueError, "LLVM verify failed: " & msg)

  result = $LLVMPrintModuleToString(llmod)
