# Semantic analysis: assign types to AST nodes.
# <NOTE>#8: context flows via SemaVisitor.ctx; if a handler ever needs a
#           different context for children it must save/restore.

import ../parser/ast
import ../types
import ../errors
import ../scope
import ../type_resolve
import ./base

type
  SemaVisitor* = object
    ctx*: LidwType   ## nil = no expectation
    symbols*: Symbols
    atTopLevel*: bool  ## true only in visitProgram's main loop
    curRetType*: LidwType  ## nil outside function body
    curLoopDepth*: int     ## 0 outside any loop



proc installBuiltins(s: var Symbols) =
  ## <NOTE>#103: builtins live in the root scope. Visible from any user
  ## scope; a user declaration in a child scope shadows them naturally.
  ## `print` is `Nul(Int)`: writes to stdout, returns nothing, so only
  ## valid in statement position (sema rejects it in value contexts).
  s.define("print", fnType(nulType(), @[i64Type()], @[muImmutable]),
           muImmutable, 0, 0)

proc newSemaVisitor*(ctx: LidwType = nil): SemaVisitor =
  result.ctx = ctx
  result.symbols = newSymbols()
  installBuiltins(result.symbols)

# Forward declarations: base.visit dispatches to all four handlers;
# without these, compiling visitUnary's body triggers visit instantiation
# while visitBinOp isn't declared yet.
proc visitInt*(v: var SemaVisitor, n: Node)
proc visitFloat*(v: var SemaVisitor, n: Node)
proc visitUnary*(v: var SemaVisitor, n: Node)
proc visitBinOp*(v: var SemaVisitor, n: Node)
proc visitBlock*(v: var SemaVisitor, n: Node)
proc visitProgram*(v: var SemaVisitor, n: Node)
proc visitDecl*(v: var SemaVisitor, n: Node)
proc visitIdent*(v: var SemaVisitor, n: Node)
proc visitAssign*(v: var SemaVisitor, n: Node)
proc visitIf*(v: var SemaVisitor, n: Node)
proc visitIs*(v: var SemaVisitor, n: Node)
proc visitCast*(v: var SemaVisitor, n: Node)
proc visitTypeName*(v: var SemaVisitor, n: Node)
proc visitFnType*(v: var SemaVisitor, n: Node)
proc visitParam*(v: var SemaVisitor, n: Node)
proc visitCall*(v: var SemaVisitor, n: Node)
proc visitRet*(v: var SemaVisitor, n: Node)
proc visitWhile*(v: var SemaVisitor, n: Node)
proc visitBreak*(v: var SemaVisitor, n: Node)
proc visitContinue*(v: var SemaVisitor, n: Node)





proc visitTypeNode*(v: var SemaVisitor, n: Node): LidwType =
  ## <NOTE>#80: resolve a type-expression AST to LidwType. Used by
  ## visitDecl. nkTypeName -> concrete kind; nkFnType -> structural
  ## function type. Anything else is a bug.
  case n.kind
  of nkTypeName: resolveTypeName(n.typeName, n.line, n.col)
  of nkFnType:
    let ret = visitTypeNode(v, n.fnRet)
    var params: seq[LidwType] = @[]
    var paramsMut: seq[Mutability] = @[]
    for p in n.fnParams:
      params.add visitTypeNode(v, p.paramType)
      paramsMut.add p.paramMut
    fnType(ret, params, paramsMut)
  of nkParam:
    visitTypeNode(v, n.paramType)
  else:
    raise newException(AssertionDefect,
      "visitTypeNode: not a type node: " & $n.kind)

# <NOTE>#54: iLit range per concrete int type. U64 upper is above int64
# max; iLit carries int64, so any non-negative value fits U64.
proc fitsIntLit(v: int64, k: TypeKind): bool =
  case k
  of tyI8:  v >= -128 and v <= 127
  of tyU8:  v >= 0 and v <= 255
  of tyI16: v >= -32768 and v <= 32767
  of tyU16: v >= 0 and v <= 65535
  of tyI32: v >= -2147483648'i64 and v <= 2147483647'i64
  of tyU32: v >= 0 and v <= 4294967295'i64
  of tyI64: true
  of tyU64: v >= 0
  else:
    raise newException(AssertionDefect,
      "fitsIntLit: not an int kind: " & $k)

proc fits*(t, ctx: LidwType): bool =
  ## Does type t satisfy expected context ctx?
  ## nil ctx = no expectation, anything fits.
  ## <NOTE>#55: no implicit conversion between concrete int types; U8
  ## does not fit U16. Widening happens only inside binary operators
  ## (7b), not here.
  if ctx == nil: return true
  if t == nil: return false
  if ctx.kind in IntKinds:
    if t.kind == tyILit:
      return fitsIntLit(t.value, ctx.kind)
    if t.kind in IntKinds:
      return t.kind == ctx.kind
    return false
  case ctx.kind
  of tyILit:
    t.kind == tyILit and t.value == ctx.value
  of tyBool:
    t.kind == tyBool or t.kind == tyILit
  of tyNul:
    t.kind == tyNul
  else:
    false

proc foldInt(op: BinOp, a, b: int64, line, col: int): int64 =
  ## Compute a op b; raise lekSema on overflow or division by zero.
  case op
  of boAdd:
    let r = a +% b
    if (b > 0 and r < a) or (b < 0 and r > a):
      raise lidwError(lekSema, "integer overflow: " & $a & " + " & $b, line, col)
    r
  of boSub:
    let r = a -% b
    if (b > 0 and r > a) or (b < 0 and r < a):
      raise lidwError(lekSema, "integer overflow: " & $a & " - " & $b, line, col)
    r
  of boMul:
    if a == 0 or b == 0: return 0
    let r = a *% b
    if r div b != a:
      raise lidwError(lekSema, "integer overflow: " & $a & " * " & $b, line, col)
    r
  of boDiv:
    if b == 0:
      raise lidwError(lekSema, "division by zero", line, col)
    if a == low(int64) and b == -1:
      raise lidwError(lekSema, "integer overflow: " & $a & " div " & $b, line, col)
    a div b
  of boMod:
    if b == 0:
      raise lidwError(lekSema, "division by zero", line, col)
    if a == low(int64) and b == -1: return 0
    a mod b
  of boEq, boNe, boLt, boLe, boGt, boGe:
    # <NOTE>#27: comparisons are handled in visitBinOp before foldInt;
    # reaching here means the dispatch above is broken.
    raise newException(AssertionDefect, "foldInt: comparison op " & opStr(op))

proc visitInt*(v: var SemaVisitor, n: Node) =
  # <NOTE>#11: literal keeps iLit under context; fits() is a check, not
  # a coercion. Overwriting typ with ctx would lose the value and hide
  # where narrowing would have to happen.
  let lt = iLitType(n.intVal)
  if v.ctx != nil and not fits(lt, v.ctx):
    raise lidwError(lekSema,
      "integer literal " & $n.intVal & " does not fit " & $v.ctx,
      n.line, n.col)
  n.typ = lt

proc visitFloat*(v: var SemaVisitor, n: Node) =
  # <TODO>#9: float types not in the system yet; leave typ nil.
  discard

proc visitUnary*(v: var SemaVisitor, n: Node) =
  # <NOTE>#57: operand is visited without ctx. Unary minus folds
  # literals (iLit(128) -> iLit(-128)) and only the RESULT is checked
  # against ctx. Otherwise `I8 x = -128` would reject the literal 128
  # before the sign is applied.
  let saveCtx = v.ctx
  v.ctx = nil
  visit(v, n.operand)
  v.ctx = saveCtx
  if n.operand.typ.kind == tyILit:
    case n.unop
    of uoNeg:
      let val = n.operand.typ.value
      if val == low(int64):
        raise lidwError(lekSema, "integer overflow: -" & $val, n.line, n.col)
      let lt = iLitType(-val)
      if v.ctx != nil and not fits(lt, v.ctx):
        raise lidwError(lekSema,
          "literal " & $lt & " does not fit " & $v.ctx, n.line, n.col)
      n.typ = lt
  else:
    if n.operand.typ.kind notin IntKinds:
      raise lidwError(lekSema,
        "unary " & unopStr(n.unop) & " requires Int, got " & $n.operand.typ,
        n.line, n.col)
    if v.ctx != nil and not fits(n.operand.typ, v.ctx):
      raise lidwError(lekSema,
        "operand of unary " & unopStr(n.unop) & " has type " & $n.operand.typ &
        ", expected " & $v.ctx, n.line, n.col)
    n.typ = n.operand.typ

proc isComparison(o: BinOp): bool =
  o in {boEq, boNe, boLt, boLe, boGt, boGe}

proc isOrdering(o: BinOp): bool =
  o in {boLt, boLe, boGt, boGe}

proc bitWidthAt(k: TypeKind): int =
  case k
  of tyI8, tyU8: 8
  of tyI16, tyU16: 16
  of tyI32, tyU32: 32
  of tyI64, tyU64: 64
  else:
    raise newException(AssertionDefect, "bitWidthAt: not an int kind: " & $k)

proc promoteIntKinds(a, b: TypeKind, line, col: int): TypeKind =
  ## <NOTE>#58: common type for arithmetic on two concrete Int kinds.
  ## Same -> same; both signed / both unsigned -> wider; mixed -> the
  ## smallest signed type that holds both (width = max(signed, unsigned+1),
  ## rounded up to 8/16/32/64). 65+ bits has no common type.
  if a == b: return a
  let aSig = a in {tyI8, tyI16, tyI32, tyI64}
  let bSig = b in {tyI8, tyI16, tyI32, tyI64}
  if aSig == bSig:
    return if bitWidthAt(a) >= bitWidthAt(b): a else: b
  let sKind = if aSig: a else: b
  let uKind = if aSig: b else: a
  let c = max(bitWidthAt(sKind), bitWidthAt(uKind) + 1)
  case c
  of 1..8: tyI8
  of 9..16: tyI16
  of 17..32: tyI32
  of 33..64: tyI64
  else:
    raise lidwError(lekSema,
      "no common type for " & $intType(a) & " and " & $intType(b),
      line, col)

proc unifyInts(a, b: LidwType, line, col: int): LidwType =
  ## <NOTE>#59: common type of arithmetic operands. Caller handles the
  ## both-iLit case (fold) before calling. Bool, Nul, and other non-Int
  ## do not unify.
  if a.kind == tyILit:
    if b.kind notin IntKinds:
      raise lidwError(lekSema,
        "arithmetic requires Int, got " & $a & " and " & $b, line, col)
    if not fitsIntLit(a.value, b.kind):
      raise lidwError(lekSema,
        "literal " & $a & " does not fit " & $b, line, col)
    return b
  if b.kind == tyILit:
    if a.kind notin IntKinds:
      raise lidwError(lekSema,
        "arithmetic requires Int, got " & $a & " and " & $b, line, col)
    if not fitsIntLit(b.value, a.kind):
      raise lidwError(lekSema,
        "literal " & $b & " does not fit " & $a, line, col)
    return a
  if a.kind notin IntKinds or b.kind notin IntKinds:
    raise lidwError(lekSema,
      "arithmetic requires Int, got " & $a & " and " & $b, line, col)
  intType(promoteIntKinds(a.kind, b.kind, line, col))

proc visitBinOp*(v: var SemaVisitor, n: Node) =
  # <NOTE>#60: operands are visited without ctx; the operator decides
  # the common type, then the result is checked against ctx.
  let saveCtx = v.ctx
  v.ctx = nil
  visit(v, n.left)
  visit(v, n.right)
  v.ctx = saveCtx

  if isComparison(n.op):
    # <NOTE>#26: comparisons produce Bool. Equality accepts Int/Int,
    # Int/iLit, Bool/Bool, Bool/iLit. Ordering accepts Int/iLit only.
    let lk = n.left.typ.kind
    let rk = n.right.typ.kind
    let lIsBool = lk == tyBool
    let rIsBool = rk == tyBool
    if lIsBool or rIsBool:
      if isOrdering(n.op):
        raise lidwError(lekSema,
          "operator " & opStr(n.op) & " requires Int operands, got " &
          $n.left.typ & " and " & $n.right.typ, n.line, n.col)
      if lIsBool and (rIsBool or rk == tyILit): discard
      elif rIsBool and lk == tyILit: discard
      else:
        raise lidwError(lekSema,
          "operator " & opStr(n.op) & " requires matching types, got " &
          $n.left.typ & " and " & $n.right.typ, n.line, n.col)
    else:
      let lIsInt = lk in IntKinds or lk == tyILit
      let rIsInt = rk in IntKinds or rk == tyILit
      if not lIsInt or not rIsInt:
        raise lidwError(lekSema,
          "operator " & opStr(n.op) & " requires Int or Bool operands, got " &
          $n.left.typ & " and " & $n.right.typ, n.line, n.col)
      let bothLit = lk == tyILit and rk == tyILit
      if not bothLit:
        discard unifyInts(n.left.typ, n.right.typ, n.line, n.col)
    n.typ = boolType()
    if v.ctx != nil and not fits(n.typ, v.ctx):
      raise lidwError(lekSema,
        "comparison result Bool does not fit " & $v.ctx, n.line, n.col)
    return

  # Arithmetic: + - * / %
  let bothLit = n.left.typ.kind == tyILit and n.right.typ.kind == tyILit
  if bothLit:
    # <NOTE>#12: literals fold regardless of context; ctx only checks
    # that the folded value fits.
    let res = foldInt(n.op, n.left.typ.value, n.right.typ.value, n.line, n.col)
    let lt = iLitType(res)
    if v.ctx != nil and not fits(lt, v.ctx):
      raise lidwError(lekSema,
        "literal " & $lt & " does not fit " & $v.ctx, n.line, n.col)
    n.typ = lt
  else:
    let unified = unifyInts(n.left.typ, n.right.typ, n.line, n.col)
    if v.ctx != nil and not fits(unified, v.ctx):
      raise lidwError(lekSema,
        "expression type " & $unified & " does not fit " & $v.ctx,
        n.line, n.col)
    n.typ = unified

proc visitProgram*(v: var SemaVisitor, n: Node) =
  # <NOTE>#33: program root is NOT a block for 'is'; a top-level nkIs
  # statement is an error (is needs a real block to yield from).
  # <NOTE>#89: two-pass sema. Pass 1 registers every top-level fn decl
  # (forward refs, recursion). Pass 2 visits bodies. Blocks stay linear.
  discard v.symbols.open()
  let saveCtx = v.ctx
  let saveTop = v.atTopLevel
  try:
    v.ctx = nil
    # Pass 1: fn symbols.
    for s in n.stmts:
      if s.kind == nkDecl and s.declTypeNode != nil and
         s.declTypeNode.kind == nkFnType:
        let fnT = visitTypeNode(v, s.declTypeNode)
        v.symbols.define(s.declName, fnT, s.declMut, s.line, s.col)
    # Pass 2: bodies.
    v.atTopLevel = true
    for s in n.stmts:
      if s.kind == nkIs:
        raise lidwError(lekSema,
          "is outside block (use `(is ...)` or a multi-stmt branch)",
          s.line, s.col)
      visit(v, s)
  finally:
    v.symbols.close()
    v.ctx = saveCtx
    v.atTopLevel = saveTop
  n.typ = nulType()

proc visitBlock*(v: var SemaVisitor, n: Node) =
  # <NOTE>#19: block yields via 'is'. Without 'is': under ctx it is an
  # error ("block has no value"); outside ctx it is a statement (nul).
  # 'is' is handled here directly (not via visitIs) so that nkIs outside
  # a block is a hard error in visitIs.
  discard v.symbols.open()
  let outerCtx = v.ctx
  let saveTop = v.atTopLevel
  v.atTopLevel = false
  # <NOTE>#121: `is` is the only yield. `ret` (and any terminal stmt)
  # marks the block as terminated: no further stmts, and the block
  # itself has type `nul` (it does not yield a value; it exits the fn).
  var yielded: Node = nil
  var terminal = false
  var terminalName = "ret"
  try:
    v.ctx = nil
    for s in n.stmts:
      if yielded != nil or terminal:
        let after = if yielded != nil: "is" else: terminalName
        raise lidwError(lekSema,
          "unreachable statement after " & after, s.line, s.col)
      if s.kind == nkIs:
        visit(v, s.isValue)
        s.typ = s.isValue.typ
        yielded = s
      else:
        visit(v, s)
        if isTerminal(s):
          terminal = true
          terminalName =
            case s.kind
            of nkBreak: "break"
            of nkContinue: "continue"
            else: "ret"



  finally:
    v.symbols.close()
    v.ctx = outerCtx
    v.atTopLevel = saveTop
  if yielded != nil:
    n.typ = yielded.typ
    if outerCtx != nil and not fits(n.typ, outerCtx):
      raise lidwError(lekSema,
        "block yields " & $n.typ & ", expected " & $outerCtx,
        n.line, n.col)
  elif terminal:
    n.typ = nulType()
  else:
    # <NOTE>#122: a non-yielding, non-terminal block is a statement
    # block: nul. Allowed under a nil ctx (statement position) and
    # under a nul ctx (body of a Nul fn). Rejected under a concrete
    # ctx — that would be a block with no value where a value is
    # expected.
    if outerCtx != nil and outerCtx.kind != tyNul:
      raise lidwError(lekSema,
        "block has no value, expected " & $outerCtx, n.line, n.col)
    n.typ = nulType()


proc visitDecl*(v: var SemaVisitor, n: Node) =
  doAssert n.declTypeNode != nil, "sema: decl without type node"
  let declT = visitTypeNode(v, n.declTypeNode)
  let isFnDecl = declT.kind == tyFn
  if isFnDecl:
    # <NOTE>#84: fn body is visited in a fresh scope. Parameters are
    # bound by name (unnamed params are not bindable). Fa.7 will honor
    # mutable params (`$`); today all params are immutable.
    # <NOTE>#89: symbol was pre-registered by visitProgram pass 1.
    # Declaring a fn inside a block is not supported.
    if not v.atTopLevel:
      raise lidwError(lekSema,
        "function declarations are only allowed at program top level",
        n.line, n.col)
    if n.declInit == nil:
      raise lidwError(lekSema,
        "function declaration requires a body: " & n.declName,
        n.line, n.col)
    let retT = declT.fnRet
    # <NOTE>#94: every parameter of a fn decl must have a name. The

    # parser accepts unnamed types so fn types are flexible in type
    # position; the decl site rejects them because a body cannot use
    # an unnamed parameter, and a caller still has to pass it.
    # <NOTE>#100: wildcard `_` will replace this rule when it lands.
    for p in n.declTypeNode.fnParams:
      if p.paramName.len == 0:
        raise lidwError(lekSema,
          "parameter must be named (use `Int()` for no parameters)",
          p.line, p.col)
    discard v.symbols.open()
    let saveCtx = v.ctx
    let saveTop = v.atTopLevel
    v.atTopLevel = false
    for i, p in n.declTypeNode.fnParams:
      if p.paramName.len > 0:
        v.symbols.define(p.paramName, declT.fnParams[i],
                         p.paramMut, p.line, p.col)
    let bodyTerminal = isTerminal(n.declInit)
    let saveRet = v.curRetType
    v.curRetType = retT
    v.ctx = retT
    visit(v, n.declInit)
    v.curRetType = saveRet
    # <NOTE>#117: a nul-typed body is a statement body; codegen appends
    # an implicit `ret <default>` of retT. Non-nul bodies must fit.
    if not bodyTerminal and n.declInit.typ != nil and
       n.declInit.typ.kind != tyNul and not fits(n.declInit.typ, retT):
      let got = $n.declInit.typ
      raise lidwError(lekSema,
        "body of " & n.declName & " has type " & got &
        ", expected " & $retT, n.declInit.line, n.declInit.col)

    v.ctx = saveCtx

    v.atTopLevel = saveTop
    v.symbols.close()
    n.typ = declT
    return
  # <NOTE>#118: Nul is a return-only type. It cannot be a variable type.
  if declT.kind == tyNul:
    raise lidwError(lekSema,
      "Nul is a return-only type; use it only as a function return type",
      n.line, n.col)
  let saveCtx = v.ctx
  v.ctx = declT
  if n.declInit != nil:
    visit(v, n.declInit)
    if n.declInit.typ == nil or not fits(n.declInit.typ, declT):
      let got = if n.declInit.typ == nil: "<untyped>" else: $n.declInit.typ
      raise lidwError(lekSema,
        "initializer of " & n.declName & " has type " & got &
        ", expected " & $declT, n.line, n.col)

  v.ctx = saveCtx
  v.symbols.define(n.declName, declT, n.declMut, n.line, n.col)
  n.typ = declT

proc visitIdent*(v: var SemaVisitor, n: Node) =
  let sym = v.symbols.lookup(n.identName)
  if sym.typ == nil:
    raise lidwError(lekSema, "undefined variable: " & n.identName, n.line, n.col)
  n.typ = sym.typ

proc visitAssign*(v: var SemaVisitor, n: Node) =
  let sym = v.symbols.lookup(n.assignName)
  if sym.typ == nil:
    raise lidwError(lekSema, "undefined variable: " & n.assignName, n.line, n.col)
  if sym.mut == muImmutable:
    raise lidwError(lekSema,
      "cannot assign to immutable variable " & n.assignName, n.line, n.col)
  let saveCtx = v.ctx
  v.ctx = sym.typ
  visit(v, n.assignValue)
  if n.assignValue.typ == nil or not fits(n.assignValue.typ, sym.typ):
    let got = if n.assignValue.typ == nil: "<untyped>" else: $n.assignValue.typ
    raise lidwError(lekSema,
      "cannot assign " & got & " to " & $sym.typ & " variable " & n.assignName,
      n.line, n.col)
  v.ctx = saveCtx
  n.typ = sym.typ

proc visitIf*(v: var SemaVisitor, n: Node) =
  let outerCtx = v.ctx
  # cond under nil ctx; then explicit fits(Bool) check
  v.ctx = nil
  visit(v, n.ifCond)
  v.ctx = outerCtx
  if not fits(n.ifCond.typ, boolType()):
    raise lidwError(lekSema,
      "if condition has type " & $n.ifCond.typ & ", expected Bool",
      n.ifCond.line, n.ifCond.col)
  # branches under outerCtx (nil in statement position)
  visit(v, n.ifThen)
  if n.ifElse != nil:
    visit(v, n.ifElse)
  # <NOTE>#112: a terminal branch (ret) leaves the function; it does
  # not produce a value for the if. Skip the fits-check for such
  # branches. If every branch is terminal, `if` is terminal too, and
  # has no value (n.typ = nul).
  let thenTerm = isTerminal(n.ifThen)
  let elseTerm = n.ifElse != nil and isTerminal(n.ifElse)
  if outerCtx == nil:
    n.typ = nulType()
  elif thenTerm and (n.ifElse == nil or elseTerm):
    # If: (a) then rets and there is no else (falls through to default),
    # or (b) both branches ret (no fall-through). Either way, the if has
    # no value; a surrounding statement context appends the default.
    n.typ = nulType()
  elif thenTerm or elseTerm:
    # One branch returns, the other yields a value. Mixing ret and value
    # in a value-context if is not supported; use `is` in a block.
    raise lidwError(lekSema,
      "ret in if branch used as value; use a block with `is`, or make both branches ret",
      n.line, n.col)
  else:
    if not fits(n.ifThen.typ, outerCtx):
      raise lidwError(lekSema,
        "if branch yields " & $n.ifThen.typ & ", expected " & $outerCtx,
        n.ifThen.line, n.ifThen.col)
    if n.ifElse != nil and not fits(n.ifElse.typ, outerCtx):
      raise lidwError(lekSema,
        "if branch yields " & $n.ifElse.typ & ", expected " & $outerCtx,
        n.ifElse.line, n.ifElse.col)
    n.typ = outerCtx



proc visitIs*(v: var SemaVisitor, n: Node) =
  # <NOTE>#34: visitBlock handles nkIs inline. Reaching here means nkIs
  # appeared where no block can catch its yield.
  raise lidwError(lekSema,
    "is outside block (use `(is ...)` or a multi-stmt branch)",
    n.line, n.col)

proc visitCast*(v: var SemaVisitor, n: Node) =
  # <NOTE>#63: cast is explicit; no fits-check on the source.
  # Source must be a value: Int, Bool, or iLit. Nul cannot be cast.
  let saveCtx = v.ctx
  v.ctx = nil
  visit(v, n.castExpr)
  v.ctx = saveCtx
  let srcKind = n.castExpr.typ.kind
  if srcKind notin IntKinds and srcKind notin {tyILit, tyBool}:
    raise lidwError(lekSema,
      "cannot cast " & $n.castExpr.typ, n.castExpr.line, n.castExpr.col)
  let target = resolveTypeName(n.castTarget, n.line, n.col)
  n.typ = target
  if v.ctx != nil and not fits(n.typ, v.ctx):
    raise lidwError(lekSema,
      "cast to " & $n.typ & " does not fit " & $v.ctx, n.line, n.col)

proc visitTypeName*(v: var SemaVisitor, n: Node) =
  # <NOTE>#78: type nodes are resolved via visitTypeNode by their parent
  # (visitDecl / visitFnType). Reaching here means a type node leaked
  # into expression position.
  raise lidwError(lekSema,
    "type name in expression position: " & n.typeName, n.line, n.col)

proc visitFnType*(v: var SemaVisitor, n: Node) =
  n.typ = visitTypeNode(v, n)

proc visitParam*(v: var SemaVisitor, n: Node) =
  n.typ = visitTypeNode(v, n.paramType)

proc visitCall*(v: var SemaVisitor, n: Node) =
  # <NOTE>#90: callee must resolve to a function type. Args count must
  # match, and each arg must fit its parameter type. Result is the
  # function's return type.
  let saveCtx = v.ctx
  v.ctx = nil
  visit(v, n.callee)
  v.ctx = saveCtx
  if n.callee.typ == nil or n.callee.typ.kind != tyFn:
    let got = if n.callee.typ == nil: "<untyped>" else: $n.callee.typ
    raise lidwError(lekSema,
      "cannot call " & got, n.callee.line, n.callee.col)
  let fnT = n.callee.typ
  if n.args.len != fnT.fnParams.len:
    raise lidwError(lekSema,
      "call expects " & $fnT.fnParams.len & " argument(s), got " &
      $n.args.len, n.line, n.col)
  # <NOTE>#95: mutable arg means "ident bound to a mutable symbol" (or,
  # in the future, a call whose return type is mutable). Literals,
  # arithmetic, comparisons, casts, if-expressions, blocks — all
  # immutable rvalues. No `!` on the call site; mutability of the
  # symbol is the whole signal.
  for i, a in n.args:
    let saveCtx2 = v.ctx
    v.ctx = nil
    visit(v, a)
    v.ctx = saveCtx2
    if a.typ == nil or not fits(a.typ, fnT.fnParams[i]):
      let got = if a.typ == nil: "<untyped>" else: $a.typ
      raise lidwError(lekSema,
        "argument " & $(i+1) & " has type " & got &
        ", expected " & $fnT.fnParams[i], a.line, a.col)
    if fnT.fnParamsMut[i] == muMutable:
      if a.kind != nkIdent:
        raise lidwError(lekSema,
          "argument " & $(i+1) & " must be mutable (ident bound to " &
          "a mutable variable), got a value expression",
          a.line, a.col)
      let sym = v.symbols.lookup(a.identName)
      if sym.typ == nil:
        raise lidwError(lekSema,
          "undefined variable: " & a.identName, a.line, a.col)
      if sym.mut != muMutable:
        raise lidwError(lekSema,
          "argument " & $(i+1) & " must be mutable, but " &
          a.identName & " is immutable", a.line, a.col)
  n.typ = fnT.fnRet

proc visitBreak*(v: var SemaVisitor, n: Node) =
  if v.curLoopDepth == 0:
    raise lidwError(lekSema,
      "break outside loop", n.line, n.col)
  n.typ = nulType()

proc visitContinue*(v: var SemaVisitor, n: Node) =
  if v.curLoopDepth == 0:
    raise lidwError(lekSema,
      "continue outside loop", n.line, n.col)
  n.typ = nulType()

proc visitRet*(v: var SemaVisitor, n: Node) =


  # <NOTE>#111: ret is only valid inside a function body. Outside,
  # suggest `is` (which yields from a block, not from a function).
  if v.curRetType == nil:
    raise lidwError(lekSema,
      "ret outside function; use `is` to yield from a block, or declare a function with a return type",
      n.line, n.col)
  if n.retExpr != nil:
    let saveCtx = v.ctx
    v.ctx = v.curRetType
    visit(v, n.retExpr)
    v.ctx = saveCtx
    if n.retExpr.typ == nil or not fits(n.retExpr.typ, v.curRetType):
      let got = if n.retExpr.typ == nil: "<untyped>" else: $n.retExpr.typ
      raise lidwError(lekSema,
        "ret value has type " & got & ", expected " & $v.curRetType,
        n.retExpr.line, n.retExpr.col)
  n.typ = v.curRetType

proc visitWhile*(v: var SemaVisitor, n: Node) =
  # <NOTE>#130: cond fits Bool. Body is a statement (nil ctx).
  # `while` yields Nul; value-loops via `break expr` are deferred.
  let outerCtx = v.ctx
  v.ctx = nil
  visit(v, n.whileCond)
  v.ctx = outerCtx
  if not fits(n.whileCond.typ, boolType()):
    raise lidwError(lekSema,
      "while condition has type " & $n.whileCond.typ & ", expected Bool",
      n.whileCond.line, n.whileCond.col)
  let saveCtx = v.ctx
  v.ctx = nil
  # <NOTE>#136: while yields Bool. true if the loop exited via break,
  # false if the condition became false. `break expr` (value-loops)
  # will change the type, see TODO.md.
  inc v.curLoopDepth
  visit(v, n.whileBody)
  dec v.curLoopDepth
  v.ctx = saveCtx
  n.typ = boolType()



proc runSema*(n: Node): Node =


  ## Run sema on n; types set in-place, n returned.
  # <NOTE>#32: no root context — program root is a statement block.
  # Context enters only via declarations (Int x = ...).
  var v = newSemaVisitor()
  visit(v, n)
  n
