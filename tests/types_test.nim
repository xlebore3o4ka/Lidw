# Type system unit tests (names, signedness, bit width).

import std/unittest
import ../src/types

suite "types":
  test "names":
    check $i8Type()  == "i8"
    check $u8Type()  == "u8"
    check $i16Type() == "i16"
    check $u16Type() == "u16"
    check $i32Type() == "i32"
    check $u32Type() == "u32"
    check $i64Type() == "i64"
    check $u64Type() == "u64"
    check $boolType() == "Bool"
    check $nulType() == "nul"
    check $iLitType(42) == "iLit(42)"

  test "signedness":
    check isSigned(i8Type())
    check isSigned(i16Type())
    check isSigned(i32Type())
    check isSigned(i64Type())
    check not isSigned(u8Type())
    check not isSigned(u16Type())
    check not isSigned(u32Type())
    check not isSigned(u64Type())

  test "bit width":
    check bitWidth(i8Type())  == 8
    check bitWidth(u8Type())  == 8
    check bitWidth(i16Type()) == 16
    check bitWidth(u16Type()) == 16
    check bitWidth(i32Type()) == 32
    check bitWidth(u32Type()) == 32
    check bitWidth(i64Type()) == 64
    check bitWidth(u64Type()) == 64

  test "iLit does not report signedness or width":
    expect AssertionDefect:
      discard isSigned(iLitType(0))
    expect AssertionDefect:
      discard bitWidth(boolType())
