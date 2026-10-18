import std/[strutils, unicode]
import ./tokens
import ../errors

type
  Lexer* = object
    src*: string
    pos*: int
    line*: int
    col*: int

# <NOTE>#13: identifier shape is ASCII-only for now; change isIdentStart /
# isIdentChar when unicode identifiers become a thing. wordKind is the
# single place deciding ident vs type by first-letter case.
proc isIdentStart*(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '_'}

proc isIdentChar*(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc wordKind*(first: char): TokenKind =
  if first in {'A'..'Z'}: tkType else: tkIdent

proc peekChar*(l: Lexer, off: int = 0): char =
  if l.pos + off < l.src.len: l.src[l.pos + off]
  else: '\0'

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

# <NOTE>#53: skipWhitespace also consumes comments (-- to EOL, and
# nestable block -/ ... /-). Comment handling lives here so every
# token sees the same trivia rule. Adjacency matters: '--' and '-/'
# are only comments when the two chars are next to each other;
# 'a - -b' is subtraction, 'a -- b' is a comment.
proc skipWhitespace(l: var Lexer) =
  while l.pos < l.src.len:
    let c = l.src[l.pos]
    if c in {' ', '\t', '\r', '\n'}:
      l.adv()
    elif c == '-' and l.pos + 1 < l.src.len and l.src[l.pos + 1] == '-':
      l.adv(); l.adv()
      while l.pos < l.src.len and l.src[l.pos] notin {'\n', '\r'}:
        l.adv()
    elif c == '-' and l.pos + 1 < l.src.len and l.src[l.pos + 1] == '/':
      let startLine = l.line
      let startCol = l.col
      l.adv(); l.adv()
      var depth = 1
      while l.pos < l.src.len and depth > 0:
        if l.pos + 1 < l.src.len and l.src[l.pos] == '-' and l.src[l.pos + 1] == '/':
          l.adv(); l.adv()
          inc depth
        elif l.pos + 1 < l.src.len and l.src[l.pos] == '/' and l.src[l.pos + 1] == '-':
          l.adv(); l.adv()
          dec depth
        else:
          l.adv()
      if depth > 0:
        raise lidwError(lekLex, "unterminated block comment", startLine, startCol)
    else:
      break

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

# <NOTE>#28: lowercase keywords; uppercase forms (If, Else) stay tkType.
# wordKind is the fallback for non-keyword words.
proc lexWord(l: var Lexer): Token =
  let startLine = l.line
  let startCol = l.col
  var s = ""
  while l.pos < l.src.len and isIdentChar(l.src[l.pos]):
    s.add l.src[l.pos]
    l.adv()
  let kind =
    case s
    of "if":   tkIf
    of "elif": tkElif
    of "else": tkElse
    of "is":   tkIs
    of "as":   tkAs
    of "ret":  tkRet
    else:      wordKind(s[0])

  Token(kind: kind, word: s, line: startLine, col: startCol)

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
    of '=':
      l.adv()
      if l.peekChar() == '=':
        l.adv()
        result.add Token(kind: tkEqEq, line: startLine, col: startCol)
      else:
        result.add Token(kind: tkEquals, line: startLine, col: startCol)
    of ';': l.adv(); result.add Token(kind: tkSemicolon, line: startLine, col: startCol)
    of ',': l.adv(); result.add Token(kind: tkComma,     line: startLine, col: startCol)
    # <NOTE>#25: '!' + '=' adjacent lexes as tkBangEq; 'Int x! = 5' needs
    # a space between ! and = to mean immutable-with-init.
    of '!':
      l.adv()
      if l.peekChar() == '=':
        l.adv()
        result.add Token(kind: tkBangEq, line: startLine, col: startCol)
      else:
        result.add Token(kind: tkBang, line: startLine, col: startCol)
    of '<':
      l.adv()
      if l.peekChar() == '=':
        l.adv()
        result.add Token(kind: tkLe, line: startLine, col: startCol)
      else:
        result.add Token(kind: tkLt, line: startLine, col: startCol)
    of '>':
      l.adv()
      if l.peekChar() == '=':
        l.adv()
        result.add Token(kind: tkGe, line: startLine, col: startCol)
      else:
        result.add Token(kind: tkGt, line: startLine, col: startCol)
    of '$': l.adv(); result.add Token(kind: tkDollar,    line: startLine, col: startCol)
    of 'a'..'z', 'A'..'Z', '_': result.add l.lexWord()
    else:
      let cp = l.src.runeAt(l.pos)
      raise lidwError(lekLex,
        "unexpected character '" & $cp & "'", startLine, startCol)
