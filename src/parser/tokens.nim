# Token definitions for the LIDW lexer.
# <NOTE>#1: minimal set for bootstrap — numbers, operators, EOF.

type
  TokenKind* = enum
    tkInt        ## integer literal
    tkFloat      ## floating-point literal
    tkPlus       ## +
    tkMinus      ## -
    tkStar       ## *
    tkSlash      ## /
    tkPercent    ## %
    tkLParen     ## (
    tkRParen     ## )
    tkEOF        ## end of input

  Token* = object
    kind*: TokenKind
    intVal*: int64    ## valid iff kind == tkInt
    floatVal*: float  ## valid iff kind == tkFloat
    line*: int        ## 1-based line of token start
    col*: int         ## 1-based column of token start

proc `$`*(t: Token): string =
  ## Human-readable form for tests and error messages.
  result = case t.kind
    of tkInt:     "tkInt(" & $t.intVal & ")"
    of tkFloat:   "tkFloat(" & $t.floatVal & ")"
    of tkPlus:    "tkPlus"
    of tkMinus:   "tkMinus"
    of tkStar:    "tkStar"
    of tkSlash:   "tkSlash"
    of tkPercent: "tkPercent"
    of tkLParen:  "tkLParen"
    of tkRParen:  "tkRParen"
    of tkEOF:     "tkEOF"
