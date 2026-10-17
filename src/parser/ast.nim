# AST for LIDW expressions.
# <NOTE>#3: variant object — exhaustive case, one allocation per node.

import std/strutils
import ../types

type
  BinOp* = enum
    boAdd, boSub, boMul, boDiv, boMod
    boEq, boNe, boLt, boLe, boGt, boGe

  UnOp* = enum
    uoNeg

  Mutability* = enum
    muMutable
    muImmutable

  NodeKind* = enum
    nkInt, nkFloat, nkUnary, nkBinOp
    nkBlock, nkProgram, nkDecl, nkIdent, nkAssign
    nkIf, nkIs

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
    of nkBlock, nkProgram:
      stmts*: seq[Node]
    of nkDecl:
      declName*: string
      declType*: string
      declMut*: Mutability
      declInit*: Node
    of nkIdent:
      identName*: string
    of nkAssign:
      assignName*: string
      assignValue*: Node
    of nkIf:
      ifCond*: Node
      ifThen*: Node
      ifElse*: Node       ## nil if no else branch
    of nkIs:
      isValue*: Node

proc opStr*(o: BinOp): string =
  case o
  of boAdd: "+"
  of boSub: "-"
  of boMul: "*"
  of boDiv: "/"
  of boMod: "%"
  of boEq: "=="
  of boNe: "!="
  of boLt: "<"
  of boLe: "<="
  of boGt: ">"
  of boGe: ">="

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
  of nkBlock, nkProgram:
    let name = if n.kind == nkBlock: "block" else: "program"
    var parts: seq[string] = @[]
    for s in n.stmts:
      parts.add render(s, depth + 1)
    if parts.len == 0:
      pad & name & " @" & $n.line & ":" & $n.col & ts
    else:
      pad & name & " @" & $n.line & ":" & $n.col & ts & "\n" & parts.join("\n")
  of nkDecl:
    let mutMark = if n.declMut == muImmutable: "!" else: ""
    let head = "decl(" & n.declName & mutMark & ": " & n.declType & ") @" &
      $n.line & ":" & $n.col & ts
    if n.declInit == nil:
      pad & head
    else:
      pad & head & "\n" & render(n.declInit, depth + 1)
  of nkIdent:
    pad & "ident(" & n.identName & ") @" & $n.line & ":" & $n.col & ts
  of nkAssign:
    pad & "assign(" & n.assignName & ") @" & $n.line & ":" & $n.col & ts & "\n" &
      render(n.assignValue, depth + 1)
  of nkIf:
    var parts: seq[string] = @[]
    parts.add pad & "if @" & $n.line & ":" & $n.col & ts
    parts.add pad & "  cond:" & "\n" & render(n.ifCond, depth + 2)
    parts.add pad & "  then:" & "\n" & render(n.ifThen, depth + 2)
    if n.ifElse != nil:
      parts.add pad & "  else:" & "\n" & render(n.ifElse, depth + 2)
    parts.join("\n")
  of nkIs:
    pad & "is @" & $n.line & ":" & $n.col & ts & "\n" &
      render(n.isValue, depth + 1)

proc `$`*(n: Node): string = render(n, 0)
