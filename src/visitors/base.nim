# Visitor dispatch over LIDW AST.
# <NOTE>#7: generic visit; V implements handlers and decides traversal order.

import ../parser/ast

proc visit*[V](v: var V, n: Node) =
  ## Dispatch on n.kind to V's handler.
  ## V must provide visitInt, visitFloat, visitUnary, visitBinOp —
  ## each with signature (var V, Node).
  ## Recursion is the visitor's responsibility; no automatic walk.
  case n.kind
  of nkInt:    v.visitInt(n)
  of nkFloat:  v.visitFloat(n)
  of nkUnary:  v.visitUnary(n)
  of nkBinOp:  v.visitBinOp(n)
  of nkBlock:  v.visitBlock(n)
  of nkProgram: v.visitProgram(n)
  of nkDecl:   v.visitDecl(n)
  of nkIdent:  v.visitIdent(n)
  of nkAssign: v.visitAssign(n)
  of nkIf:     v.visitIf(n)
  of nkIs:     v.visitIs(n)
  of nkCast:   v.visitCast(n)
  of nkTypeName: v.visitTypeName(n)
  of nkFnType: v.visitFnType(n)
  of nkParam:  v.visitParam(n)
  of nkCall:   v.visitCall(n)
  of nkRet:    v.visitRet(n)
  of nkWhile:  v.visitWhile(n)
  of nkBreak:  v.visitBreak(n)
  of nkContinue: v.visitContinue(n)
  of nkDiscard:  v.visitDiscard(n)






when isMainModule:
  # smoke: prove dispatch type-checks; no real visitor yet.
  type Noop = object
  proc visitInt*(v: var Noop, n: Node) = discard
  proc visitFloat*(v: var Noop, n: Node) = discard
  proc visitUnary*(v: var Noop, n: Node) = discard
  proc visitBinOp*(v: var Noop, n: Node) = discard
  proc visitBlock*(v: var Noop, n: Node) = discard
  proc visitProgram*(v: var Noop, n: Node) = discard
  proc visitDecl*(v: var Noop, n: Node) = discard
  proc visitIdent*(v: var Noop, n: Node) = discard
  proc visitAssign*(v: var Noop, n: Node) = discard
  proc visitIf*(v: var Noop, n: Node) = discard
  proc visitIs*(v: var Noop, n: Node) = discard
  proc visitCast*(v: var Noop, n: Node) = discard
  proc visitTypeName*(v: var Noop, n: Node) = discard
  proc visitFnType*(v: var Noop, n: Node) = discard
  proc visitParam*(v: var Noop, n: Node) = discard
  proc visitCall*(v: var Noop, n: Node) = discard
  proc visitRet*(v: var Noop, n: Node) = discard
  proc visitWhile*(v: var Noop, n: Node) = discard
  proc visitBreak*(v: var Noop, n: Node) = discard
  proc visitContinue*(v: var Noop, n: Node) = discard
  proc visitDiscard*(v: var Noop, n: Node) = discard





  var v: Noop
  let n = Node(kind: nkInt, intVal: 1)
  visit(v, n)
