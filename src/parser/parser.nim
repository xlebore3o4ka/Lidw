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
proc parseStmt(p: var Parser): Node

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
  of tkIdent:
    p.advance()
    result = Node(kind: nkIdent, identName: t.word, line: t.line, col: t.col)
  of tkType:
    raise lidwError(lekParse, "expected expression, got type " & t.word,
                    t.line, t.col)
  of tkLParen:
    let lparen = t
    p.advance()
    var stmts: seq[Node] = @[]
    while true:
      while p.peek().kind == tkSemicolon: p.advance()
      if p.peek().kind in {tkRParen, tkEOF}: break
      stmts.add parseStmt(p)
    let closing = p.peek()
    if closing.kind != tkRParen:
      raise lidwError(lekParse, "expected ')' but got end of input",
                      closing.line, closing.col)
    p.advance()
    if stmts.len == 0:
      raise lidwError(lekParse, "empty parentheses", lparen.line, lparen.col)
    if stmts.len == 1:
      result = stmts[0]
    else:
      result = Node(kind: nkBlock, stmts: stmts, line: lparen.line, col: lparen.col)
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

proc parseDecl(p: var Parser): Node =
  let typeTok = p.peek()
  p.advance()
  let nameTok = p.peek()
  if nameTok.kind != tkIdent:
    raise lidwError(lekParse,
      "expected identifier after type " & typeTok.word, nameTok.line, nameTok.col)
  p.advance()
  # <NOTE>#22: '!' marks immutable, '$' marks mutable explicitly; both are
  # optional postfixes on the name, before '='.
  var mut = muMutable
  if p.peek().kind == tkBang:
    mut = muImmutable
    p.advance()
  elif p.peek().kind == tkDollar:
    p.advance()
  if p.peek().kind == tkEquals:
    let eqTok = p.peek()
    p.advance()
    let iv = parseExpr(p, 0)
    result = Node(kind: nkDecl, declName: nameTok.word, declType: typeTok.word,
                  declMut: mut, declInit: iv, line: eqTok.line, col: eqTok.col)
  else:
    result = Node(kind: nkDecl, declName: nameTok.word, declType: typeTok.word,
                  declMut: mut, declInit: nil, line: nameTok.line, col: nameTok.col)

proc parseAssign(p: var Parser): Node =
  let nameTok = p.peek()
  p.advance()
  let eqTok = p.peek()
  p.advance()
  let val = parseExpr(p, 0)
  result = Node(kind: nkAssign, assignName: nameTok.word, assignValue: val,
                line: eqTok.line, col: eqTok.col)

proc parseStmt(p: var Parser): Node =
  let t = p.peek()
  if t.kind == tkType:
    parseDecl(p)
  elif t.kind == tkIdent and p.tokens[p.pos + 1].kind == tkEquals:
    parseAssign(p)
  else:
    parseExpr(p, 0)

proc parseProgram*(tokens: seq[Token]): Node =
  var p = Parser(tokens: tokens, pos: 0)
  var stmts: seq[Node] = @[]
  while true:
    while p.peek().kind == tkSemicolon: p.advance()
    if p.peek().kind == tkEOF: break
    stmts.add parseStmt(p)
  if stmts.len > 0:
    result = Node(kind: nkBlock, stmts: stmts, line: stmts[0].line, col: stmts[0].col)
  else:
    result = Node(kind: nkBlock, stmts: @[], line: 1, col: 1)
