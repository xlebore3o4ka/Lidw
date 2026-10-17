import std/[strutils, unicode]
import ./tokens
import ../errors

type
  Lexer* = object
    src*: string
    pos*: int
    line*: int
    col*: int

proc initLexer*(src: string): Lexer =
  Lexer(src: src, pos: 0, line: 1, col: 1)

proc adv(l: var Lexer) =
  if l.pos < l.src.len:
    if l.src[l.pos] == '\n':
      inc l.line
      l.col = 1
    else:
      inc l.col
    inc l.pos

proc skipWhitespace(l: var Lexer) =
  while l.pos < l.src.len and l.src[l.pos] in {' ', '\t', '\r', '\n'}:
    l.adv()

proc lexNumber(l: var Lexer): Token =
  let startLine = l.line
  let startCol = l.col
  var s = ""
  var isFloat = false
  while l.pos < l.src.len and l.src[l.pos] in {'0'..'9'}:
    s.add l.src[l.pos]
    l.adv()
  if l.pos < l.src.len and l.src[l.pos] == '.':
    isFloat = true
    s.add '.'
    l.adv()
    while l.pos < l.src.len and l.src[l.pos] in {'0'..'9'}:
      s.add l.src[l.pos]
      l.adv()
  if isFloat:
    Token(kind: tkFloat, floatVal: parseFloat(s), line: startLine, col: startCol)
  else:
    Token(kind: tkInt, intVal: parseInt(s).int64, line: startLine, col: startCol)

proc lexAll*(src: string): seq[Token] =
  var l = initLexer(src)
  while true:
    l.skipWhitespace()
    let startLine = l.line
    let startCol = l.col
    if l.pos >= l.src.len:
      result.add Token(kind: tkEOF, line: startLine, col: startCol)
      break
    let c = l.src[l.pos]
    case c
    of '0'..'9': result.add l.lexNumber()
    of '+': l.adv(); result.add Token(kind: tkPlus,    line: startLine, col: startCol)
    of '-': l.adv(); result.add Token(kind: tkMinus,   line: startLine, col: startCol)
    of '*': l.adv(); result.add Token(kind: tkStar,    line: startLine, col: startCol)
    of '/': l.adv(); result.add Token(kind: tkSlash,   line: startLine, col: startCol)
    of '%': l.adv(); result.add Token(kind: tkPercent, line: startLine, col: startCol)
    of '(': l.adv(); result.add Token(kind: tkLParen,  line: startLine, col: startCol)
    of ')': l.adv(); result.add Token(kind: tkRParen,  line: startLine, col: startCol)
    else:
      let cp = l.src.runeAt(l.pos)
      raise lidwError(lekLex,
        "unexpected character '" & $cp & "'", startLine, startCol)
