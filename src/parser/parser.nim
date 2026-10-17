# Recursive-descent parser for LIDW expressions.
# <NOTE>#4: precedence climbing — left-assoc binary ops, unary minus binds tightest.

import ./tokens
import ./ast
import ../types
import ../errors

type
  Parser* = object
    tokens*: seq[Token]
    pos*: int

proc peek(p: Parser): Token = p.tokens[p.pos]
proc advance(p: var Parser) = inc p.pos

proc precedence(kind: TokenKind): int =
  case kind
  of tkPlus, tkMinus: 1
  of tkStar, tkSlash, tkPercent: 2
  else: 0

proc binOpFrom(kind: TokenKind): BinOp =
  case kind
  of tkPlus: boAdd
  of tkMinus: boSub
  of tkStar: boMul
  of tkSlash: boDiv
  of tkPercent: boMod
  else:
    raise newException(AssertionDefect, "binOpFrom: not a binary op: " & $kind)

proc parseExpr(p: var Parser, minPrec: int): Node

proc parsePrimary(p: var Parser): Node =
  let t = p.peek()
  case t.kind
  of tkInt:
    p.advance()
    result = Node(kind: nkInt, intVal: t.intVal, line: t.line, col: t.col)
    result.typ = iLitType(t.intVal)
  of tkFloat:
    p.advance()
    result = Node(kind: nkFloat, floatVal: t.floatVal, line: t.line, col: t.col)
  of tkLParen:
    p.advance()
    result = parseExpr(p, 0)
    let closing = p.peek()
    if closing.kind != tkRParen:
      let what = if closing.kind == tkEOF: "end of input" else: $closing
      raise lidwError(lekParse, "expected ')' but got " & what,
                      closing.line, closing.col)
    p.advance()
  else:
    raise lidwError(lekParse, "unexpected token: " & $t, t.line, t.col)

proc parseUnary(p: var Parser): Node =
  let t = p.peek()
  if t.kind == tkMinus:
    p.advance()
    let operand = parseUnary(p)
    result = Node(kind: nkUnary, unop: uoNeg, operand: operand,
                  line: t.line, col: t.col)
  else:
    result = parsePrimary(p)

proc parseExpr(p: var Parser, minPrec: int): Node =
  result = parseUnary(p)
  while true:
    let t = p.peek()
    let prec = precedence(t.kind)
    if prec == 0 or prec < minPrec:
      break
    p.advance()
    let rhs = parseExpr(p, prec + 1)
    result = Node(kind: nkBinOp, op: binOpFrom(t.kind),
                  left: result, right: rhs, line: t.line, col: t.col)

proc parse*(tokens: seq[Token]): Node =
  var p = Parser(tokens: tokens, pos: 0)
  result = parseExpr(p, 0)
  let trailing = p.peek()
  if trailing.kind != tkEOF:
    raise lidwError(lekParse, "unexpected token after expression: " & $trailing,
                    trailing.line, trailing.col)
