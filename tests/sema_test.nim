# Semantic analyzer unit tests.

import std/unittest
import std/strutils
import ../src/parser/lexer
import ../src/parser/ast
import ../src/parser/parser
import ../src/types
import ../src/visitors/sema
import ../src/errors

proc sema(src: string): Node =
  runSema(parseProgram(lexAll(src)))

proc expectSema(src: string): LidwErrorKind =
  try:
    discard sema(src)
    raise newException(AssertionDefect, "expected sema error for: " & src)
  except LidwError as e:
    result = e.kind

suite "sema":
  test "literal-only binop folds to iLit":
    let n = sema("10 + 4")
    let e = n.stmts[0]
    check e.kind == nkBinOp
    check e.typ.kind == tyILit
    check e.typ.value == 14

  test "literal fold under decl ctx stays iLit":
    let n = sema("Int x = 10 + 4")
    let d = n.stmts[0]
    check d.typ.kind == tyI64
    check d.declInit.typ.kind == tyILit
    check d.declInit.typ.value == 14

  test "decl init keeps iLit, decl gets i64":
    let n = sema("Int x = 10")
    let d = n.stmts[0]
    check d.typ.kind == tyI64
    check d.declInit.typ.kind == tyILit
    check d.declInit.typ.value == 10

  test "I64 aliases Int":
    let n = sema("I64 x = 10")
    check n.stmts[0].typ.kind == tyI64

  test "x + 1 unifies to i64":
    let n = sema("Int x = 10 x + 1")
    let d = n.stmts[0]
    check d.typ.kind == tyI64
    let e = n.stmts[1]
    check e.kind == nkBinOp
    check e.typ.kind == tyI64
    check e.left.kind == nkIdent and e.left.typ.kind == tyI64

  test "decl referencing earlier decl":
    let n = sema("Int x = 10 Int y = x")
    check n.stmts.len == 2
    check n.stmts[0].typ.kind == tyI64
    check n.stmts[1].typ.kind == tyI64
    check n.stmts[1].declInit.kind == nkIdent
    check n.stmts[1].declInit.typ.kind == tyI64

  test "assign type checked":
    let n = sema("Int x = 10 x = 5")
    check n.stmts.len == 2
    check n.stmts[1].kind == nkAssign
    check n.stmts[1].typ.kind == tyI64
    check n.stmts[1].assignValue.typ.kind == tyILit

  test "unary minus on literal folds":
    let n = sema("-5")
    let e = n.stmts[0]
    check e.kind == nkUnary
    check e.typ.kind == tyILit
    check e.typ.value == -5

  test "unary minus on var keeps i64":
    let n = sema("Int x = 5; -x")
    check n.stmts.len == 2
    check n.stmts[1].kind == nkUnary
    check n.stmts[1].typ.kind == tyI64
    check n.stmts[1].operand.kind == nkIdent

  test "undefined variable":
    check expectSema("x + 1") == lekSema

  test "unknown type":
    check expectSema("Foo x = 10") == lekSema

  test "use before decl":
    check expectSema("Int y = x Int x = 1") == lekSema

  test "assign to undefined":
    check expectSema("x = 5") == lekSema

  test "block scope closes":
    # y bound inside block must not leak
    check expectSema("(Int y = 10; y) Int z = y") == lekSema

  test "block in value position is error without is":
    try:
      discard sema("Int x = (Int y = 10; 5)")
      check false
    except LidwError as e:
      check e.kind == lekSema
      check "block has no value" in e.msg

  test "block without ctx is nul":
    let n = sema("(1 2)")
    check n.stmts[0].kind == nkBlock
    check n.stmts[0].typ.kind == tyNul

  test "root program is nul":
    let n = sema("Int x = 10")
    check n.typ.kind == tyNul

  test "block nul does not unify with iLit":
    check expectSema("(1 2) + 1") == lekSema

  test "block nul does not fit i64":
    check expectSema("Int x = (1 2)") == lekSema

  test "redefinition in same scope":
    try:
      discard sema("Int x = 10 Int x = 20")
      check false
    except LidwError as e:
      check e.kind == lekSema
      check "redeclaration of x" in e.msg
      check "previously declared at 1:7" in e.msg
      check e.line == 1 and e.col == 18

  test "shadowing in nested scope is ok":
    let n = sema("Int x = 10 (Int x = 20 x)")
    check n.stmts.len == 2
    check n.stmts[0].kind == nkDecl and n.stmts[0].declName == "x"
    check n.stmts[1].kind == nkBlock
    check n.stmts[1].stmts.len == 2
    check n.stmts[1].stmts[0].kind == nkDecl and n.stmts[1].stmts[0].declName == "x"
    check n.stmts[1].stmts[1].kind == nkIdent

  test "outer x visible after inner block closes":
    let n = sema("Int x = 10 (Int x = 20 x) x + 1")
    check n.stmts.len == 3
    check n.stmts[1].kind == nkBlock
    check n.stmts[2].kind == nkBinOp
    check n.stmts[2].typ.kind == tyI64
    check n.stmts[2].left.kind == nkIdent and n.stmts[2].left.typ.kind == tyI64

  test "assign to immutable variable":
    try:
      discard sema("Int x! = 10 x = 5")
      check false
    except LidwError as e:
      check e.kind == lekSema
      check "cannot assign to immutable variable x" in e.msg

  test "assign to explicit-mutable via dollar":
    let n = sema("Int x$ = 10 x = 5")
    check n.stmts.len == 2
    check n.stmts[1].kind == nkAssign

  test "immutable declared without init, then read":
    let n = sema("Int x! Int y = x")
    check n.stmts.len == 2
    check n.stmts[0].declMut == muImmutable
    check n.stmts[1].typ.kind == tyI64
    check n.stmts[1].declInit.kind == nkIdent
    check n.stmts[1].declInit.typ.kind == tyI64

  test "immutable with different decl and use positions redeclare fails":
    try:
      discard sema("Int x! = 1 Int x = 2")
      check false
    except LidwError as e:
      check e.kind == lekSema
      check "redeclaration of x" in e.msg

  test "comparison produces Bool":
    let n = sema("Bool b = 1 < 2")
    check n.stmts[0].kind == nkDecl
    check n.stmts[0].typ.kind == tyBool
    check n.stmts[0].declInit.typ.kind == tyBool

  test "iLit under Bool context stays iLit":
    let n = sema("Bool b = 1")
    check n.stmts[0].typ.kind == tyBool
    check n.stmts[0].declInit.typ.kind == tyILit

  test "Bool equality with iLit":
    let n = sema("Bool b = 1 Bool c = b == 0")
    check n.stmts[1].typ.kind == tyBool
    check n.stmts[1].declInit.typ.kind == tyBool

  test "Int variable ordering":
    let n = sema("Int x = 5 Bool b = x < 10")
    check n.stmts[1].typ.kind == tyBool
    check n.stmts[1].declInit.typ.kind == tyBool

  test "comparison result does not fit Int":
    check expectSema("Int x = 1 < 2") == lekSema

  test "ordering on Bool is error":
    check expectSema("Bool b = 1 Int x = (b < 2)") == lekSema

  test "mismatched equality Int and Bool":
    check expectSema("Int x = 1 Bool b = 0 Bool c = (x == b)") == lekSema

  test "Bool does not fit Int":
    check expectSema("Bool b = 1 Int x = b") == lekSema

  test "Int does not fit Bool":
    check expectSema("Int x = 1 Bool b = x") == lekSema

  test "arithmetic on Bool is error":
    check expectSema("Bool b = 1 Bool c = b + 1") == lekSema

  test "unary minus on Bool is error":
    check expectSema("Bool b = 1 Int x = -b") == lekSema

  test "nul fits nul":
    let n = sema("1")
    check n.stmts[0].typ.kind == tyILit

  test "nul does not fit i64 context":
    # we cannot yet produce a nul-typed value in source; this checks
    # the fits table directly
    check not fits(nulType(), i64Type())

  test "i64 does not fit nul context":
    check not fits(i64Type(), nulType())

  test "iLit does not fit nul context":
    check not fits(iLitType(0), nulType())

  test "bool does not fit nul context":
    check not fits(boolType(), nulType())

  test "nul fits nul context":
    check fits(nulType(), nulType())

  test "nul does not fit bool context":
    check not fits(nulType(), boolType())
