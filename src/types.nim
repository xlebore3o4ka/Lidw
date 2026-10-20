import std/strutils
# Type system for LIDW.
# <NOTE>#6: iLit carries the literal value; coerces to i64 when needed.

type
  Mutability* = enum
    muMutable
    muImmutable

  TypeKind* = enum
    tyI8, tyU8
    tyI16, tyU16
    tyI32, tyU32
    tyI64, tyU64
    tyILit   ## untyped integer literal (value known, bitness unknown)
    tyBool   ## boolean
    tyNul    ## no value (statement position)
    tyFn     ## function type
    tyF32    ## 32-bit IEEE 754 float
    tyF64    ## 64-bit IEEE 754 float
    tyFLit   ## untyped float literal


  LidwType* = ref object
    case kind*: TypeKind
    of tyI8, tyU8, tyI16, tyU16, tyI32, tyU32, tyI64, tyU64: discard
    of tyILit: value*: int64
    of tyBool: discard
    of tyNul: discard
    of tyFn:
      fnRet*: LidwType
      fnParams*: seq[LidwType]
      fnParamsMut*: seq[Mutability]
    of tyF32: discard
    of tyF64: discard
    of tyFLit: fValue*: float



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

proc fnType*(ret: LidwType, params: seq[LidwType],
              paramsMut: seq[Mutability]): LidwType =
  doAssert params.len == paramsMut.len, "fnType: paramsMut length mismatch"
  LidwType(kind: tyFn, fnRet: ret, fnParams: params,
           fnParamsMut: paramsMut)

proc f32Type*(): LidwType = LidwType(kind: tyF32)
proc f64Type*(): LidwType = LidwType(kind: tyF64)
proc fLitType*(v: float): LidwType = LidwType(kind: tyFLit, fValue: v)


const FloatKinds* = {tyF32, tyF64}

proc isFloatKind*(t: LidwType): bool = t.kind in FloatKinds


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
  of tyF32: 32
  of tyF64: 64
  else:
    raise newException(AssertionDefect,
      "bitWidth: not an int or float type: " & $t.kind)


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
  of tyFn:
    var parts: seq[string] = @[]
    for p in t.fnParams:
      parts.add $p
    $t.fnRet & "(" & parts.join(", ") & ")"
  of tyF32: "f32"
  of tyF64: "f64"
  of tyFLit: "fLit(" & $t.fValue & ")"


