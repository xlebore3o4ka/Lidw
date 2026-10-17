# Type system for LIDW.
# <NOTE>#6: iLit carries the literal value; coerces to i64 when needed.

type
  TypeKind* = enum
    tyI64    ## concrete 64-bit signed integer
    tyILit   ## untyped integer literal (value known, bitness unknown)

  LidwType* = ref object
    case kind*: TypeKind
    of tyI64: discard
    of tyILit: value*: int64

proc i64Type*(): LidwType =
  LidwType(kind: tyI64)

proc iLitType*(v: int64): LidwType =
  LidwType(kind: tyILit, value: v)

proc `$`*(t: LidwType): string =
  case t.kind
  of tyI64: "i64"
  of tyILit: "iLit(" & $t.value & ")"
