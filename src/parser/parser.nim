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
proc parseWhileLike(p: var Parser, tok: Token): Node


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
  of tkWhile:
    p.advance()
    result = parseWhileLike(p, t)

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

proc parseAsPostfix(p: var Parser): Node
proc parseCall(p: var Parser): Node

# <NOTE>#86: precedence, loosest to tightest:
#   binary (in parseExpr loop) < as < unary < call < primary.
# `-1 as U8` is `(-1) as U8`, `-f(1)` is `-(f(1))`,
# `f(1) as U8` is `(f(1)) as U8`.
proc parseUnary(p: var Parser): Node =
  let t = p.peek()
  if t.kind == tkMinus:
    p.advance()
    let operand = parseUnary(p)
    result = Node(kind: nkUnary, unop: uoNeg, operand: operand,
                  line: t.line, col: t.col)
  else:
    result = parseCall(p)

# <NOTE>#85: call is the tightest postfix. `(f)(1)` calls a grouped
# ident. <NOTE>#87: a call only attaches when the callee is callable
# (ident, call, cast). This keeps `if 1 (1 2) else 0` parsing as
# "cond = 1, then = block (1 2)" rather than trying to call `1`.
proc isCallable(n: Node): bool =
  n.kind in {nkIdent, nkCall, nkCast}

proc parseCall(p: var Parser): Node =
  result = parsePrimary(p)
  while p.peek().kind == tkLParen and isCallable(result):
    let lpTok = p.peek()
    let savePos = p.pos
    p.advance()
    var args: seq[Node] = @[]
    var ok = true
    while true:
      if p.peek().kind == tkRParen: break
      args.add parseExpr(p, 0)
      if p.peek().kind == tkComma:
        p.advance()
        continue
      break
    # <NOTE>#88: if '(' did not close as a call, rewind and let the
    # caller parse '(' as a block/grouping. This keeps `if c (1 2)`
    # meaning "cond=c, then=block(1,2)" instead of a malformed call.
    if p.peek().kind != tkRParen:
      p.pos = savePos
      ok = false
    if not ok: break
    p.advance()
    result = Node(kind: nkCall, callee: result, args: args,
                  line: lpTok.line, col: lpTok.col)

# <NOTE>#62: `as` is above binary, below unary. Left-associative chain.
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
  # <NOTE>#107: assignment is the lowest-precedence expression, right-
  # associative: `a = b = c` is `a = (b = c)`. Only attempted at top
  # level (minPrec == 0), so `1 + a = 2` does NOT parse as
  # `1 + (a = 2)`. Target must be a bare ident.
  # <NOTE>#109: `ret` is top-level like assignment. `ret` then:
  #  - `;`, `)`, else, elif, EOF -> bare ret (return default).
  #  - otherwise -> ret <expr>, parsed at minPrec 0.
  if minPrec == 0 and p.peek().kind == tkRet:
    let retTok = p.peek()
    p.advance()
    if p.peek().kind in {tkSemicolon, tkRParen, tkEOF, tkElse, tkElif}:
      return Node(kind: nkRet, retExpr: nil, line: retTok.line, col: retTok.col)
    let e = parseExpr(p, 0)
    return Node(kind: nkRet, retExpr: e, line: retTok.line, col: retTok.col)
  if minPrec == 0 and p.peek().kind == tkIdent and
     p.tokens[p.pos + 1].kind == tkEquals:
    let nameTok = p.peek()
    p.advance()   # ident
    p.advance()   # =
    let val = parseExpr(p, 0)
    return Node(kind: nkAssign, assignName: nameTok.word,
                assignValue: val, line: nameTok.line, col: nameTok.col)
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

# <NOTE>#77: type-expression grammar.
#   type   ::= tkType [ '(' [param {',' param}] ')' ]
#   param  ::= type [tkIdent [mutpostfix]]
#   mutpostfix ::= '!' | '$'
# `T` alone -> nkTypeName. `T(A, B)` -> nkFnType with params.
proc parseType(p: var Parser): Node

proc parseParam(p: var Parser): Node =
  let ty = parseType(p)
  var name = ""
  var mut = muImmutable
  var endLine = ty.line
  var endCol = ty.col
  if p.peek().kind == tkIdent:
    let nameTok = p.peek()
    p.advance()
    name = nameTok.word
    endLine = nameTok.line
    endCol = nameTok.col
    if p.peek().kind == tkBang:
      let mTok = p.peek()
      mut = muImmutable
      endLine = mTok.line
      endCol = mTok.col
      p.advance()
    elif p.peek().kind == tkDollar:
      let mTok = p.peek()
      mut = muMutable
      endLine = mTok.line
      endCol = mTok.col
      p.advance()
  Node(kind: nkParam, paramType: ty, paramName: name, paramMut: mut,
       line: endLine, col: endCol)

proc parseType(p: var Parser): Node =
  let t = p.peek()
  if t.kind != tkType:
    raise lidwError(lekParse,
      "expected type, got " & $t, t.line, t.col)
  p.advance()
  if p.peek().kind != tkLParen:
    return Node(kind: nkTypeName, typeName: t.word, line: t.line, col: t.col)
  # function type T(A, B)
  p.advance()
  var params: seq[Node] = @[]
  while true:
    if p.peek().kind == tkRParen: break
    params.add parseParam(p)
    if p.peek().kind == tkComma:
      p.advance()
      continue
    break
  let closing = p.peek()
  if closing.kind != tkRParen:
    raise lidwError(lekParse,
      "expected ')' in function type, got " & $closing,
      closing.line, closing.col)
  p.advance()
  let ret = Node(kind: nkTypeName, typeName: t.word, line: t.line, col: t.col)
  Node(kind: nkFnType, fnRet: ret, fnParams: params,
       line: t.line, col: t.col)

proc parseDecl(p: var Parser): Node =
  let typeNode = parseType(p)
  let nameTok = p.peek()
  if nameTok.kind != tkIdent:
    raise lidwError(lekParse,
      "expected identifier after type " & typeNodeStr(typeNode),
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
  if p.peek().kind == tkEquals:
    let eqTok = p.peek()
    p.advance()
    let iv = parseExpr(p, 0)
    result = Node(kind: nkDecl, declName: nameTok.word,
                  declTypeNode: typeNode, declMut: mut, declInit: iv,
                  line: eqTok.line, col: eqTok.col)
  else:
    result = Node(kind: nkDecl, declName: nameTok.word,
                  declTypeNode: typeNode, declMut: mut, declInit: nil,
                  line: nameTok.line, col: nameTok.col)

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

# <NOTE>#129: while cond body. Body follows the if-branch rule: one
# statement without parens, or an explicit `( ... )` block. `while`
# is a statement (yields Nul); `break expr` for value-loops is
# deferred (see TODO.md).
proc parseWhileLike(p: var Parser, tok: Token): Node =
  let cond = parseExpr(p, 0)
  let body = parseBodyNode(p, "while", tok.line, tok.col)
  Node(kind: nkWhile, whileCond: cond, whileBody: body,
       line: tok.line, col: tok.col)

proc parseStmt(p: var Parser): Node =
  let t = p.peek()
  if t.kind == tkType:
    parseDecl(p)
  elif t.kind == tkIf:
    p.advance()
    parseIfLike(p, t)
  elif t.kind == tkWhile:
    p.advance()
    parseWhileLike(p, t)
  elif t.kind == tkBreak:
    p.advance()
    Node(kind: nkBreak, line: t.line, col: t.col)
  elif t.kind == tkContinue:
    p.advance()
    Node(kind: nkContinue, line: t.line, col: t.col)
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
