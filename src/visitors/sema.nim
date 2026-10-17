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

proc newSemaVisitor*(ctx: LidwType = nil): SemaVisitor =
  SemaVisitor(ctx: ctx, symbols: newSymbols())

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

proc visitBinOp*(v: var SemaVisitor, n: Node) =
  visit(v, n.left)
  visit(v, n.right)

  if isComparison(n.op):
    # <NOTE>#26: comparisons produce Bool. Equality accepts (Int, iLit)
    # or (Bool, iLit); ordering accepts Int operands only. No value
    # folding: we keep Bool without a literal payload.
    let lk = n.left.typ.kind
    let rk = n.right.typ.kind
    let bothInt = lk in {tyI64, tyILit} and rk in {tyI64, tyILit}
    if isOrdering(n.op):
      if not bothInt:
        raise lidwError(lekSema,
          "operator " & opStr(n.op) & " requires Int operands, got " &
          $n.left.typ & " and " & $n.right.typ, n.line, n.col)
    else:
      let eqOk = bothInt or
                 (lk == tyBool and rk in {tyBool, tyILit}) or
                 (rk == tyBool and lk in {tyBool, tyILit})
      if not eqOk:
        raise lidwError(lekSema,
          "operator " & opStr(n.op) & " requires matching types, got " &
          $n.left.typ & " and " & $n.right.typ, n.line, n.col)
    n.typ = boolType()
    if v.ctx != nil and not fits(n.typ, v.ctx):
      raise lidwError(lekSema,
        "comparison result Bool does not fit " & $v.ctx, n.line, n.col)
    return

  let bothLit = n.left.typ.kind == tyILit and n.right.typ.kind == tyILit

  if bothLit:
    # <NOTE>#12: literals fold through binary op regardless of context.
    # Context only checks the folded value fits; it never coerces the
    # result to a concrete type.
    let res = foldInt(n.op, n.left.typ.value, n.right.typ.value, n.line, n.col)
    let lt = iLitType(res)
    if v.ctx != nil and not fits(lt, v.ctx):
      raise lidwError(lekSema,
        "literal " & $lt & " does not fit " & $v.ctx, n.line, n.col)
    n.typ = lt
  else:
    # <NOTE>#20: at least one operand is concrete; unify operands.
    # i64 beats iLit; anything else is a type mismatch.
    let unified =
      if n.left.typ.kind == tyI64 or n.right.typ.kind == tyI64: i64Type()
      else: nil
    if unified == nil:
      raise lidwError(lekSema,
        "cannot unify " & $n.left.typ & " and " & $n.right.typ &
        " for " & opStr(n.op), n.line, n.col)
    if v.ctx != nil and not fits(unified, v.ctx):
      raise lidwError(lekSema,
        "expression type " & $unified & " does not fit " & $v.ctx,
        n.line, n.col)
    n.typ = unified

proc visitProgram*(v: var SemaVisitor, n: Node) =
  # <NOTE>#33: program root is NOT a block for 'is'; a top-level nkIs
  # statement is an error (is needs a real block to yield from).
  discard v.symbols.open()
  let saveCtx = v.ctx
  try:
    v.ctx = nil
    for s in n.stmts:
      if s.kind == nkIs:
        raise lidwError(lekSema,
          "is outside block (use `(is ...)` or a multi-stmt branch)",
          s.line, s.col)
      visit(v, s)
  finally:
    v.symbols.close()
    v.ctx = saveCtx
  n.typ = nulType()

proc visitBlock*(v: var SemaVisitor, n: Node) =
  # <NOTE>#19: block yields via 'is'. Without 'is': under ctx it is an
  # error ("block has no value"); outside ctx it is a statement (nul).
  # 'is' is handled here directly (not via visitIs) so that nkIs outside
  # a block is a hard error in visitIs.
  discard v.symbols.open()
  let outerCtx = v.ctx
  var yielded: Node = nil
  try:
    v.ctx = nil
    for s in n.stmts:
      if yielded != nil:
        raise lidwError(lekSema,
          "unreachable statement after is", s.line, s.col)
      if s.kind == nkIs:
        visit(v, s.isValue)
        s.typ = s.isValue.typ
        yielded = s
      else:
        visit(v, s)
  finally:
    v.symbols.close()
    v.ctx = outerCtx
  if yielded != nil:
    n.typ = yielded.typ
    if outerCtx != nil and not fits(n.typ, outerCtx):
      raise lidwError(lekSema,
        "block yields " & $n.typ & ", expected " & $outerCtx,
        n.line, n.col)
  else:
    if outerCtx != nil:
      raise lidwError(lekSema,
        "block has no value, expected " & $outerCtx, n.line, n.col)
    n.typ = nulType()

proc visitDecl*(v: var SemaVisitor, n: Node) =
  let declT = resolveTypeName(n.declType, n.line, n.col)
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
  # result
  if outerCtx == nil:
    n.typ = nulType()
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

proc runSema*(n: Node): Node =
  ## Run sema on n; types set in-place, n returned.
  # <NOTE>#32: no root context — program root is a statement block.
  # Context enters only via declarations (Int x = ...).
  var v = newSemaVisitor()
  visit(v, n)
  n
