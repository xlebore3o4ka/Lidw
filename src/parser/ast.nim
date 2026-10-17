# AST for LIDW expressions.
# <NOTE>#3: variant object — exhaustive case, one allocation per node.

import std/strutils
import ../types

type
  BinOp* = enum
    boAdd, boSub, boMul, boDiv, boMod

  UnOp* = enum
    uoNeg

  NodeKind* = enum
    nkInt, nkFloat, nkUnary, nkBinOp
    nkBlock, nkDecl, nkIdent, nkAssign

  Node* = ref object
    line*: int
    col*: int
    typ*: LidwType
    case kind*: NodeKind
    of nkInt:
      intVal*: int64
    of nkFloat:
      floatVal*: float
    of nkUnary:
      unop*: UnOp
      operand*: Node
    of nkBinOp:
      op*: BinOp
      left*: Node
      right*: Node
    of nkBlock:
      stmts*: seq[Node]
    of nkDecl:
      declName*: string
      declType*: string
      declInit*: Node
    of nkIdent:
      identName*: string
    of nkAssign:
      assignName*: string
      assignValue*: Node

proc opStr*(o: BinOp): string =
  case o
  of boAdd: "+"
  of boSub: "-"
  of boMul: "*"
  of boDiv: "/"
  of boMod: "%"

proc unopStr*(o: UnOp): string =
  case o
  of uoNeg: "-"

proc typeSuffix(n: Node): string =
  if n.typ == nil: "" else: " [" & $n.typ & "]"

proc render(n: Node, depth: int): string =
  let pad = "  ".repeat(depth)
  let ts = typeSuffix(n)
  case n.kind
  of nkInt:
    pad & "int(" & $n.intVal & ") @" & $n.line & ":" & $n.col & ts
  of nkFloat:
    pad & "float(" & $n.floatVal & ") @" & $n.line & ":" & $n.col & ts
  of nkUnary:
    pad & "unary(" & unopStr(n.unop) & ") @" & $n.line & ":" & $n.col & ts & "\n" &
      render(n.operand, depth + 1)
  of nkBinOp:
    pad & "binOp(" & opStr(n.op) & ") @" & $n.line & ":" & $n.col & ts & "\n" &
      render(n.left, depth + 1) & "\n" &
      render(n.right, depth + 1)
  of nkBlock:
    var parts: seq[string] = @[]
    for s in n.stmts:
      parts.add render(s, depth + 1)
    if parts.len == 0:
      pad & "block @" & $n.line & ":" & $n.col & ts
    else:
      pad & "block @" & $n.line & ":" & $n.col & ts & "\n" & parts.join("\n")
  of nkDecl:
    if n.declInit == nil:
      pad & "decl(" & n.declName & ": " & n.declType & ") @" & $n.line & ":" & $n.col & ts
    else:
      pad & "decl(" & n.declName & ": " & n.declType & ") @" & $n.line & ":" & $n.col & ts & "\n" &
        render(n.declInit, depth + 1)
  of nkIdent:
    pad & "ident(" & n.identName & ") @" & $n.line & ":" & $n.col & ts
  of nkAssign:
    pad & "assign(" & n.assignName & ") @" & $n.line & ":" & $n.col & ts & "\n" &
      render(n.assignValue, depth + 1)

proc `$`*(n: Node): string = render(n, 0)
