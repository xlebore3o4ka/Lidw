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
  of tkEqEq, tkBangEq, tkLt, tkLe, tkGt, tkGe: 1
  of tkPlus, tkMinus: 2
  of tkStar, tkSlash, tkPercent: 3
  else: 0

proc binOpFrom(kind: TokenKind): BinOp =
  case kind
  of tkPlus: boAdd
  of tkMinus: boSub
  of tkStar: boMul
  of tkSlash: boDiv
  of tkPercent: boMod
  of tkEqEq: boEq
  of tkBangEq: boNe
  of tkLt: boLt
  of tkLe: boLe
  of tkGt: boGt
  of tkGe: boGe
  else:
    raise newException(AssertionDefect, "binOpFrom: not a binary op: " & $kind)

proc parseExpr(p: var Parser, minPrec: int): Node
proc parseStmt(p: var Parser): Node
proc parseIfLike(p: var Parser, tok: Token): Node

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
  of tkIf:
    p.advance()
    result = parseIfLike(p, t)
  of tkIs:
    p.advance()
    let val = parseExpr(p, 0)
    result = Node(kind: nkIs, isValue: val, line: t.line, col: t.col)
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
    # <NOTE>#29: '(is ...)' must stay a block — 'is' needs a block context.
    if stmts.len == 1 and stmts[0].kind != nkIs:
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

# <NOTE>#62: `as` binds tighter than binary ops, looser than unary,
# like in Rust: `-x as U8` = `(-x) as U8`, `2 * 5 as U8` = `2 * (5 as U8)`.
proc parseAsPostfix(p: var Parser): Node =
  result = parseUnary(p)
  while p.peek().kind == tkAs:
    let asTok = p.peek()
    p.advance()
    let tyTok = p.peek()
    if tyTok.kind != tkType:
      raise lidwError(lekParse,
        "expected type after 'as', got " & $tyTok, tyTok.line, tyTok.col)
    p.advance()
    result = Node(kind: nkCast, castTarget: tyTok.word, castExpr: result,
                  line: asTok.line, col: asTok.col)

proc parseExpr(p: var Parser, minPrec: int): Node =
  result = parseAsPostfix(p)
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

# <NOTE>#77: parseType handles a single type-expression. Today it is
# just `tkType -> nkTypeName`. Function types T(A, B) land in Fa.2.
proc parseType(p: var Parser): Node =
  let t = p.peek()
  if t.kind != tkType:
    raise lidwError(lekParse,
      "expected type, got " & $t, t.line, t.col)
  p.advance()
  Node(kind: nkTypeName, typeName: t.word, line: t.line, col: t.col)

proc parseDecl(p: var Parser): Node =
  let typeTok = p.peek()
  let typeNode = parseType(p)
  let nameTok = p.peek()
  if nameTok.kind != tkIdent:
    raise lidwError(lekParse,
      "expected identifier after type " & typeTok.word,
      nameTok.line, nameTok.col)
  p.advance()
  # <NOTE>#22: '!' marks immutable, '$' marks mutable explicitly; both are
  # optional postfixes on the name, before '='.
  var mut = muMutable
  if p.peek().kind == tkBang:
    mut = muImmutable
    p.advance()
  elif p.peek().kind == tkDollar:
    p.advance()
  let typeName =
    if typeNode.kind == nkTypeName: typeNode.typeName else: ""
  if p.peek().kind == tkEquals:
    let eqTok = p.peek()
    p.advance()
    let iv = parseExpr(p, 0)
    result = Node(kind: nkDecl, declName: nameTok.word, declType: typeName,
                  declTypeNode: typeNode, declMut: mut, declInit: iv,
                  line: eqTok.line, col: eqTok.col)
  else:
    result = Node(kind: nkDecl, declName: nameTok.word, declType: typeName,
                  declTypeNode: typeNode, declMut: mut, declInit: nil,
                  line: nameTok.line, col: nameTok.col)

proc parseAssign(p: var Parser): Node =
  let nameTok = p.peek()
  p.advance()
  let eqTok = p.peek()
  p.advance()
  let val = parseExpr(p, 0)
  result = Node(kind: nkAssign, assignName: nameTok.word, assignValue: val,
                line: eqTok.line, col: eqTok.col)

# <NOTE>#48: an if/else branch takes exactly ONE statement without
# parentheses. A multi-stmt body must be an explicit `( ... )` block.
# This prevents a bare branch from absorbing the next statement of the
# enclosing scope, and it keeps `nkBlock` strictly tied to parentheses.
proc parseBodyNode(p: var Parser, what: string, line, col: int): Node =
  while p.peek().kind == tkSemicolon: p.advance()
  if p.peek().kind in {tkElif, tkElse, tkEOF, tkRParen}:
    raise lidwError(lekParse, what & " requires a body", line, col)
  parseStmt(p)

proc parseIfLike(p: var Parser, tok: Token): Node =
  ## Called after tkIf/tkElif was consumed. tok is that token.
  let cond = parseExpr(p, 0)
  let thenBr = parseBodyNode(p, "if", tok.line, tok.col)
  while p.peek().kind == tkSemicolon: p.advance()
  var elseBr: Node = nil
  if p.peek().kind == tkElif:
    let elifTok = p.peek()
    p.advance()
    elseBr = parseIfLike(p, elifTok)
  elif p.peek().kind == tkElse:
    let elseTok = p.peek()
    p.advance()
    elseBr = parseBodyNode(p, "else", elseTok.line, elseTok.col)
  Node(kind: nkIf, ifCond: cond, ifThen: thenBr, ifElse: elseBr,
       line: tok.line, col: tok.col)

proc parseStmt(p: var Parser): Node =
  let t = p.peek()
  if t.kind == tkType:
    parseDecl(p)
  elif t.kind == tkIf:
    p.advance()
    parseIfLike(p, t)
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
    result = Node(kind: nkProgram, stmts: stmts, line: stmts[0].line, col: stmts[0].col)
  else:
    result = Node(kind: nkProgram, stmts: @[], line: 1, col: 1)
