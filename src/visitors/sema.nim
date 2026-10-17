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
  if v.ctx == nil:
    n.typ = iLitType(n.intVal)
  elif fits(iLitType(n.intVal), v.ctx):
    n.typ = v.ctx
  else:
    raise lidwError(lekSema,
      "integer literal " & $n.intVal & " does not fit " & $v.ctx,
      n.line, n.col)

proc visitFloat*(v: var SemaVisitor, n: Node) =
  # <TODO>#9: float types not in the system yet; leave typ nil.
  discard

proc visitUnary*(v: var SemaVisitor, n: Node) =
  visit(v, n.operand)
  if v.ctx != nil:
    if not fits(n.operand.typ, v.ctx):
      raise lidwError(lekSema,
        "operand of unary " & unopStr(n.unop) & " has type " & $n.operand.typ &
        ", expected " & $v.ctx, n.line, n.col)
    n.typ = v.ctx
  else:
    case n.unop
    of uoNeg:
      if n.operand.typ.kind == tyILit:
        let val = n.operand.typ.value
        if val == low(int64):
          raise lidwError(lekSema, "integer overflow: -" & $val, n.line, n.col)
        n.typ = iLitType(-val)
      else:
        n.typ = n.operand.typ

proc visitBinOp*(v: var SemaVisitor, n: Node) =
  visit(v, n.left)
  visit(v, n.right)

  if v.ctx != nil:
    if not fits(n.left.typ, v.ctx):
      raise lidwError(lekSema,
        "left operand of " & opStr(n.op) & " has type " & $n.left.typ &
        ", expected " & $v.ctx, n.line, n.col)
    if not fits(n.right.typ, v.ctx):
      raise lidwError(lekSema,
        "right operand of " & opStr(n.op) & " has type " & $n.right.typ &
        ", expected " & $v.ctx, n.line, n.col)
    n.typ = v.ctx
  else:
    if n.left.typ.kind == tyILit and n.right.typ.kind == tyILit:
      let res = foldInt(n.op, n.left.typ.value, n.right.typ.value, n.line, n.col)
      n.typ = iLitType(res)
    else:
      # <TODO>#10: mixed types without context — unreachable today, but
      # will be reachable once variables exist; then decide promote/error.
      raise lidwError(lekSema,
        "cannot type " & opStr(n.op) & " without context: " &
        $n.left.typ & " vs " & $n.right.typ, n.line, n.col)

proc runSema*(n: Node, ctx: LidwType = nil): Node =
  ## Run sema on n with the given context; types set in-place, n returned.
  var v = newSemaVisitor(ctx)
  visit(v, n)
  n
