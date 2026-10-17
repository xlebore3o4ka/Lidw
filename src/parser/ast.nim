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

proc `$`*(n: Node): string = render(n, 0)
