# LIDW error types.
# <NOTE>#2: user-facing errors are LidwError, never bare ValueError.

type
  LidwErrorKind* = enum
    lekLex, lekParse, lekSema, lekRuntime

  LidwError* = object of CatchableError
    kind*: LidwErrorKind
    line*: int
    col*: int

proc lidwError*(kind: LidwErrorKind, msg: string, line, col: int): ref LidwError =
  ## Build a LidwError with position info. `msg` goes to Exception.msg.
  result = newException(LidwError, msg)
  result.kind = kind
  result.line = line
  result.col = col

proc kindName*(k: LidwErrorKind): string =
  case k
  of lekLex:     "lex"
  of lekParse:   "parse"
  of lekSema:    "sema"
  of lekRuntime: "runtime"
