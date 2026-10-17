# Semantic analysis: assign types to AST nodes.
# <NOTE>#8: context flows via SemaVisitor.ctx; if a handler ever needs a
#           different context for children it must save/restore.

import ../parser/ast
import ../types
import ../errors
import ./base

type
  SemaVisitor* = object
    ctx*: LidwType   ## nil = no expectation

proc newSemaVisitor*(ctx: LidwType = nil): SemaVisitor =
  SemaVisitor(ctx: ctx)

# Forward declarations: base.visit dispatches to all four handlers;
# without these, compiling visitUnary's body triggers visit instantiation
# while visitBinOp isn't declared yet.
proc visitInt*(v: var SemaVisitor, n: Node)
proc visitFloat*(v: var SemaVisitor, n: Node)
proc visitUnary*(v: var SemaVisitor, n: Node)
proc visitBinOp*(v: var SemaVisitor, n: Node)

proc fits*(t, ctx: LidwType): bool =
  ## Does type t satisfy expected context ctx?
  ## nil ctx = no expectation, anything fits.
  if ctx == nil: return true
  case ctx.kind
  of tyI64:
    case t.kind
    of tyI64:  true
    of tyILit: true          # int64 value always inside i64 range
  of tyILit:
    case t.kind
    of tyILit: t.value == ctx.value
    of tyI64:  false

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
  visit(v, n.operand)
  if n.operand.typ.kind == tyILit:
    # <NOTE>#12: literal folds through unary regardless of context;
    # context only checks the folded value fits.
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
    if v.ctx == nil:
      raise lidwError(lekSema,
        "cannot type unary " & unopStr(n.unop) & " on " & $n.operand.typ &
        " without context", n.line, n.col)
    if not fits(n.operand.typ, v.ctx):
      raise lidwError(lekSema,
        "operand of unary " & unopStr(n.unop) & " has type " & $n.operand.typ &
        ", expected " & $v.ctx, n.line, n.col)
    n.typ = v.ctx

proc visitBinOp*(v: var SemaVisitor, n: Node) =
  visit(v, n.left)
  visit(v, n.right)

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
    # <TODO>#10: at least one operand is non-literal; result takes the
    # expected type. Unreachable until variables exist.
    if v.ctx == nil:
      raise lidwError(lekSema,
        "cannot type " & opStr(n.op) & " without context: " &
        $n.left.typ & " vs " & $n.right.typ, n.line, n.col)
    if not fits(n.left.typ, v.ctx):
      raise lidwError(lekSema,
        "left operand of " & opStr(n.op) & " has type " & $n.left.typ &
        ", expected " & $v.ctx, n.line, n.col)
    if not fits(n.right.typ, v.ctx):
      raise lidwError(lekSema,
        "right operand of " & opStr(n.op) & " has type " & $n.right.typ &
        ", expected " & $v.ctx, n.line, n.col)
    n.typ = v.ctx

proc runSema*(n: Node, ctx: LidwType = nil): Node =
  ## Run sema on n with the given context; types set in-place, n returned.
  var v = newSemaVisitor(ctx)
  visit(v, n)
  n
