# Type system for LIDW.
# <NOTE>#6: iLit carries the literal value; coerces to i64 when needed.

type
  TypeKind* = enum
    tyI8, tyU8
    tyI16, tyU16
    tyI32, tyU32
    tyI64, tyU64
    tyILit   ## untyped integer literal (value known, bitness unknown)
    tyBool   ## boolean
    tyNul    ## no value (statement position)

  LidwType* = ref object
    case kind*: TypeKind
    of tyI8, tyU8, tyI16, tyU16, tyI32, tyU32, tyI64, tyU64: discard
    of tyILit: value*: int64
    of tyBool: discard
    of tyNul: discard

const IntKinds* = {tyI8, tyU8, tyI16, tyU16, tyI32, tyU32, tyI64, tyU64}

proc intType*(kind: TypeKind): LidwType =
  doAssert kind in IntKinds, "intType: not an int kind: " & $kind
  LidwType(kind: kind)

proc i8Type*():  LidwType = intType(tyI8)
proc u8Type*():  LidwType = intType(tyU8)
proc i16Type*(): LidwType = intType(tyI16)
proc u16Type*(): LidwType = intType(tyU16)
proc i32Type*(): LidwType = intType(tyI32)
proc u32Type*(): LidwType = intType(tyU32)
proc i64Type*(): LidwType = intType(tyI64)
proc u64Type*(): LidwType = intType(tyU64)

proc iLitType*(v: int64): LidwType =
  LidwType(kind: tyILit, value: v)

proc boolType*(): LidwType =
  LidwType(kind: tyBool)

proc nulType*(): LidwType =
  LidwType(kind: tyNul)

proc isSigned*(t: LidwType): bool =
  case t.kind
  of tyI8, tyI16, tyI32, tyI64: true
  of tyU8, tyU16, tyU32, tyU64: false
  else:
    raise newException(AssertionDefect,
      "isSigned: not an int type: " & $t.kind)

proc bitWidth*(t: LidwType): int =
  case t.kind
  of tyI8, tyU8: 8
  of tyI16, tyU16: 16
  of tyI32, tyU32: 32
  of tyI64, tyU64: 64
  else:
    raise newException(AssertionDefect,
      "bitWidth: not an int type: " & $t.kind)

proc `$`*(t: LidwType): string =
  case t.kind
  of tyI8: "i8"
  of tyU8: "u8"
  of tyI16: "i16"
  of tyU16: "u16"
  of tyI32: "i32"
  of tyU32: "u32"
  of tyI64: "i64"
  of tyU64: "u64"
  of tyILit: "iLit(" & $t.value & ")"
  of tyBool: "Bool"
  of tyNul: "nul"
