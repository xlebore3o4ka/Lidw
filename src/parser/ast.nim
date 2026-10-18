# AST for LIDW expressions.
# <NOTE>#3: variant object — exhaustive case, one allocation per node.

import std/strutils
import ../types
export Mutability

type
  BinOp* = enum
    boAdd, boSub, boMul, boDiv, boMod
    boEq, boNe, boLt, boLe, boGt, boGe

  UnOp* = enum
    uoNeg

  NodeKind* = enum
    nkInt, nkFloat, nkUnary, nkBinOp
    nkBlock, nkProgram, nkDecl, nkIdent, nkAssign
    nkIf, nkIs, nkCast
    nkTypeName, nkFnType, nkParam
    nkCall
    nkRet
    nkWhile
    nkBreak
    nkContinue





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
      declTypeNode*: Node
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
    of nkCast:
      castTarget*: string
      castExpr*: Node
    of nkTypeName:
      typeName*: string
    of nkFnType:
      fnRet*: Node
      fnParams*: seq[Node]
    of nkParam:
      paramType*: Node
      paramName*: string        ## "" for unnamed parameter
      paramMut*: Mutability
    of nkCall:
      callee*: Node
      args*: seq[Node]
    of nkRet:
      retExpr*: Node       ## nil for bare `ret` (return default)
    of nkWhile:
      whileCond*: Node
      whileBody*: Node
    of nkBreak: discard
    of nkContinue: discard





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

proc isTerminal*(n: Node): bool =
  ## <NOTE>#110: structural terminality. True if control cannot fall
  ## through n. Used by sema (unreachable-after) and codegen (skip
  ## trailing ret, drop merge blocks).
  if n == nil: return false
  case n.kind
  of nkRet: true
  of nkBreak: true
  of nkContinue: true


  of nkBlock, nkProgram:
    n.stmts.len > 0 and isTerminal(n.stmts[^1])
  of nkIf:
    n.ifElse != nil and isTerminal(n.ifThen) and isTerminal(n.ifElse)
  of nkDecl:
    n.declInit != nil and isTerminal(n.declInit)
  else: false

proc typeNodeStr*(n: Node): string =

  ## <NOTE>#83: render a type-expression as source-style text.
  ## Used by `$`-render of nkDecl when sema hasn't run (typ == nil) and
  ## by parser error messages.
  if n == nil: return ""
  case n.kind
  of nkTypeName: n.typeName
  of nkFnType:
    var parts: seq[string] = @[]
    for p in n.fnParams:
      parts.add typeNodeStr(p.paramType)
    typeNodeStr(n.fnRet) & "(" & parts.join(", ") & ")"
  of nkParam: typeNodeStr(n.paramType)
  else: "<type>"

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
    let typeStr =
      if n.declTypeNode != nil: typeNodeStr(n.declTypeNode)
      elif n.typ != nil: $n.typ
      else: "?"
    let head = "decl(" & n.declName & mutMark & ": " & typeStr & ") @" &
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
  of nkCast:
    pad & "cast(" & n.castTarget & ") @" & $n.line & ":" & $n.col & ts & "\n" &
      render(n.castExpr, depth + 1)
  of nkTypeName:
    pad & "type(" & n.typeName & ") @" & $n.line & ":" & $n.col
  of nkFnType:
    var parts: seq[string] = @[]
    parts.add pad & "fnType @" & $n.line & ":" & $n.col & ts
    parts.add pad & "  ret:" & "\n" & render(n.fnRet, depth + 2)
    for p in n.fnParams:
      parts.add pad & "  param:" & "\n" & render(p, depth + 2)
    parts.join("\n")
  of nkParam:
    # <NOTE>#96: params are immutable by default. `$` is the only
    # postfix; `!` on a param is redundant (parser accepts it as no-op
    # for now, render doesn't show it).
    let mutMark = if n.paramMut == muMutable: "$" else: ""
    let nameS = if n.paramName.len > 0: n.paramName & mutMark else: "_"
    pad & "param(" & nameS & ") @" & $n.line & ":" & $n.col & "\n" &
      render(n.paramType, depth + 1)
  of nkCall:
    var parts: seq[string] = @[]
    parts.add pad & "call @" & $n.line & ":" & $n.col & ts
    parts.add pad & "  callee:" & "\n" & render(n.callee, depth + 2)
    for a in n.args:
      parts.add pad & "  arg:" & "\n" & render(a, depth + 2)
    parts.join("\n")
  of nkRet:
    if n.retExpr == nil:
      pad & "ret @" & $n.line & ":" & $n.col & ts
    else:
      pad & "ret @" & $n.line & ":" & $n.col & ts & "\n" &
        render(n.retExpr, depth + 1)
  of nkWhile:
    var parts: seq[string] = @[]
    parts.add pad & "while @" & $n.line & ":" & $n.col & ts
    parts.add pad & "  cond:" & "\n" & render(n.whileCond, depth + 2)
    parts.add pad & "  body:" & "\n" & render(n.whileBody, depth + 2)
    parts.join("\n")
  of nkBreak:
    pad & "break @" & $n.line & ":" & $n.col & ts
  of nkContinue:
    pad & "continue @" & $n.line & ":" & $n.col & ts





proc `$`*(n: Node): string = render(n, 0)
