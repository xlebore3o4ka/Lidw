# Parser unit tests.

import std/unittest
import ../src/parser/lexer
import ../src/parser/ast
import ../src/parser/parser
import ../src/errors

proc p(src: string): Node = parseProgram(lexAll(src))

proc expectParse(src: string): LidwErrorKind =
  try:
    discard p(src)
    raise newException(AssertionDefect, "expected parse error for: " & src)
  except LidwError as e:
    result = e.kind

suite "parser":
  test "single expression wrapped in program block":
    let n = p("10 + 4")
    check n.kind == nkProgram
    check n.stmts.len == 1
    check n.stmts[0].kind == nkBinOp
    check n.stmts[0].op == boAdd
    check n.stmts[0].left.kind == nkInt and n.stmts[0].left.intVal == 10
    check n.stmts[0].right.kind == nkInt and n.stmts[0].right.intVal == 4

  test "decl with init":
    let n = p("Int x = 10")
    check n.stmts.len == 1
    let d = n.stmts[0]
    check d.kind == nkDecl
    check d.declName == "x"
    check d.declType == "Int"
    check d.declInit != nil
    check d.declInit.kind == nkInt and d.declInit.intVal == 10

  test "decl without init":
    let n = p("Int x")
    check n.stmts[0].kind == nkDecl
    check n.stmts[0].declInit == nil

  test "two decls without semicolon":
    let n = p("Int x = 10 Int y = 20")
    check n.stmts.len == 2
    check n.stmts[0].declName == "x"
    check n.stmts[1].declName == "y"

  test "semicolon separator":
    let n = p("Int x = 10; Int y = 20")
    check n.stmts.len == 2

  test "trailing and leading semicolons allowed":
    let n = p(";;; Int x = 10;; Int y = 20;;;")
    check n.stmts.len == 2
    check n.stmts[0].declName == "x"
    check n.stmts[1].declName == "y"

  test "empty input and semicolons-only":
    check p("").stmts.len == 0
    check p(";;;").stmts.len == 0

  test "assign":
    let n = p("x = 5")
    check n.stmts.len == 1
    check n.stmts[0].kind == nkAssign
    check n.stmts[0].assignName == "x"
    check n.stmts[0].assignValue.kind == nkInt

  test "ident as expression":
    let n = p("x")
    check n.stmts[0].kind == nkIdent
    check n.stmts[0].identName == "x"

  test "parens with single stmt are grouping":
    let n = p("(1 + 2)")
    check n.stmts.len == 1
    check n.stmts[0].kind == nkBinOp

  test "parens with two stmts become block":
    let n = p("(1 2)")
    check n.stmts.len == 1
    check n.stmts[0].kind == nkBlock
    check n.stmts[0].stmts.len == 2

  test "semicolon splits inside parens":
    let n = p("(Int x = 5; -x)")
    check n.stmts[0].kind == nkBlock
    check n.stmts[0].stmts.len == 2
    check n.stmts[0].stmts[0].kind == nkDecl
    check n.stmts[0].stmts[1].kind == nkUnary

  test "type token in expr position is parse error":
    check expectParse("Int x = )") == lekParse
    check expectParse("Int") == lekParse

  test "empty parens are parse error":
    check expectParse("()") == lekParse
    check expectParse("(;)") == lekParse

  test "decl mutable by default":
    let n = p("Int x = 10")
    check n.stmts[0].declMut == muMutable

  test "decl immutable via bang":
    let n = p("Int x! = 10")
    check n.stmts[0].kind == nkDecl
    check n.stmts[0].declName == "x"
    check n.stmts[0].declMut == muImmutable

  test "decl mutable via dollar":
    let n = p("Int x$ = 10")
    check n.stmts[0].declMut == muMutable

  test "immutable decl without init":
    let n = p("Int x!")
    check n.stmts[0].kind == nkDecl
    check n.stmts[0].declInit == nil
    check n.stmts[0].declMut == muImmutable

  test "use-postfix is still parse error":
    check expectParse("Int x = 10; x!") == lekParse

  test "comparison precedence lower than add":
    let n = p("1 + 2 < 3")
    check n.stmts[0].kind == nkBinOp
    check n.stmts[0].op == boLt
    check n.stmts[0].left.kind == nkBinOp
    check n.stmts[0].left.op == boAdd
    check n.stmts[0].right.kind == nkInt

  test "comparison left-assoc":
    let n = p("1 < 2 < 3")
    check n.stmts[0].kind == nkBinOp
    check n.stmts[0].op == boLt
    check n.stmts[0].left.kind == nkBinOp
    check n.stmts[0].left.op == boLt

  test "not-equal token parses":
    let n = p("1 != 2")
    check n.stmts[0].kind == nkBinOp
    check n.stmts[0].op == boNe

  test "adjacent bang-equals in decl is parse error":
    check expectParse("Int x!=5") == lekParse

  test "if branch without parens is one stmt":
    let n = p("if 1 x = 5 x")
    check n.stmts.len == 2
    check n.stmts[0].kind == nkIf
    check n.stmts[0].ifThen.kind == nkAssign
    check n.stmts[0].ifElse == nil
    check n.stmts[1].kind == nkIdent
    check n.stmts[1].identName == "x"

  test "semicolon after if else ends the if":
    let n = p("if 1 10 else 20; x")
    check n.stmts.len == 2
    check n.stmts[0].kind == nkIf
    check n.stmts[0].ifThen.kind == nkInt
    check n.stmts[0].ifElse.kind == nkInt
    check n.stmts[1].kind == nkIdent
    check n.stmts[1].identName == "x"

  test "if branch multi-stmt requires parens":
    let n = p("if 1 (1 2) else 0")
    check n.stmts[0].ifThen.kind == nkBlock
    check n.stmts[0].ifThen.stmts.len == 2

  test "if branch without body is parse error":
    check expectParse("if 1") == lekParse
    check expectParse("if 1 1 else") == lekParse
