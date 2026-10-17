# Lexer unit tests.

import std/unittest
import std/strutils
import ../src/parser/tokens
import ../src/parser/lexer
import ../src/errors

suite "lexer":
  test "single int with position":
    let ts = lexAll("1")
    check ts.len == 2
    check ts[0].kind == tkInt
    check ts[0].intVal == 1
    check ts[0].line == 1
    check ts[0].col == 1
    check ts[1].kind == tkEOF

  test "int + int positions":
    let ts = lexAll("1 + 2")
    check ts.len == 4
    check ts[0].kind == tkInt and ts[0].col == 1
    check ts[1].kind == tkPlus and ts[1].col == 3
    check ts[2].kind == tkInt and ts[2].col == 5
    check ts[3].kind == tkEOF and ts[3].col == 6

  test "parens and ops":
    let ts = lexAll("(10 + 4) * 5")
    check ts.len == 8
    check ts[0].kind == tkLParen
    check ts[1].kind == tkInt and ts[1].intVal == 10
    check ts[2].kind == tkPlus
    check ts[3].kind == tkInt and ts[3].intVal == 4
    check ts[4].kind == tkRParen
    check ts[5].kind == tkStar
    check ts[6].kind == tkInt and ts[6].intVal == 5
    check ts[7].kind == tkEOF

  test "ident vs type by first letter":
    let ts = lexAll("Int x = 10")
    check ts[0].kind == tkType and ts[0].word == "Int"
    check ts[1].kind == tkIdent and ts[1].word == "x"
    check ts[2].kind == tkEquals
    check ts[3].kind == tkInt and ts[3].intVal == 10

  test "lowercase int is ident":
    let ts = lexAll("int")
    check ts[0].kind == tkIdent
    check ts[0].word == "int"

  test "underscore does not make type":
    check lexAll("_x")[0].kind == tkIdent
    check lexAll("X_")[0].kind == tkType
    check lexAll("_")[0].kind == tkIdent

  test "semicolon token":
    check lexAll(";")[0].kind == tkSemicolon

  test "float":
    let ts = lexAll("1.5")
    check ts[0].kind == tkFloat
    check ts[0].floatVal == 1.5

  test "unexpected ascii char":
    try:
      discard lexAll("@")
      check false
    except LidwError as e:
      check e.kind == lekLex
      check e.line == 1 and e.col == 1

  test "unexpected cyrillic keeps position":
    try:
      discard lexAll("п")
      check false
    except LidwError as e:
      check e.kind == lekLex
      check e.line == 1 and e.col == 1

  test "bang and dollar tokens":
    check lexAll("!")[0].kind == tkBang
    check lexAll("$")[0].kind == tkDollar
    let ts = lexAll("Int x! = 10")
    check ts.len == 6
    check ts[0].kind == tkType
    check ts[1].kind == tkIdent and ts[1].word == "x"
    check ts[2].kind == tkBang
    check ts[3].kind == tkEquals
    check ts[4].kind == tkInt and ts[4].intVal == 10
    check ts[5].kind == tkEOF

  test "dollar in decl position":
    let ts = lexAll("Int x$ = 10")
    check ts[2].kind == tkDollar

  test "comparison operator tokens":
    check lexAll("<")[0].kind == tkLt
    check lexAll("<=")[0].kind == tkLe
    check lexAll(">")[0].kind == tkGt
    check lexAll(">=")[0].kind == tkGe
    check lexAll("==")[0].kind == tkEqEq
    check lexAll("!=")[0].kind == tkBangEq

  test "bang adjacent to equals is bangEq":
    check lexAll("x != y")[1].kind == tkBangEq

  test "bang followed by space stays bang":
    let ts = lexAll("x! = y")
    check ts[1].kind == tkBang
    check ts[2].kind == tkEquals

  test "if/elif/else/is are keywords":
    check lexAll("if")[0].kind == tkIf
    check lexAll("elif")[0].kind == tkElif
    check lexAll("else")[0].kind == tkElse
    check lexAll("is")[0].kind == tkIs

  test "uppercase If is a type, not keyword":
    check lexAll("If")[0].kind == tkType
    check lexAll("Else")[0].kind == tkType
    check lexAll("Is")[0].kind == tkType

  test "if-else-if lexes as three keywords":
    let ts = lexAll("if else elif is")
    check ts[0].kind == tkIf
    check ts[1].kind == tkElse
    check ts[2].kind == tkElif
    check ts[3].kind == tkIs
    check ts[4].kind == tkEOF

  test "word does not prefix-match keyword":
    check lexAll("iff")[0].kind == tkIdent
    check lexAll("elsewhere")[0].kind == tkIdent
    check lexAll("issue")[0].kind == tkIdent

  test "line comment to end of line":
    let ts = lexAll("a -- comment\nb")
    check ts.len == 3
    check ts[0].kind == tkIdent and ts[0].word == "a"
    check ts[1].kind == tkIdent and ts[1].word == "b"
    check ts[1].line == 2
    check ts[2].kind == tkEOF

  test "line comment at EOF without newline":
    let ts = lexAll("a -- trailing")
    check ts.len == 2
    check ts[0].kind == tkIdent and ts[0].word == "a"
    check ts[1].kind == tkEOF

  test "block comment inline":
    let ts = lexAll("a -/ ignored /- b")
    check ts.len == 3
    check ts[0].kind == tkIdent and ts[0].word == "a"
    check ts[1].kind == tkIdent and ts[1].word == "b"

  test "nested block comment":
    let ts = lexAll("-/ -/ x /- /- 1")
    check ts.len == 2
    check ts[0].kind == tkInt and ts[0].intVal == 1
    check ts[1].kind == tkEOF

  test "block comment spanning lines tracks line":
    let ts = lexAll("a\n-/ one\ntwo /-\nb")
    check ts.len == 3
    check ts[0].line == 1
    check ts[1].kind == tkIdent and ts[1].word == "b"
    check ts[1].line == 4

  test "cyrillic inside comment is fine":
    let ts = lexAll("a -- привет\nb")
    check ts.len == 3
    check ts[0].kind == tkIdent and ts[0].word == "a"
    check ts[1].kind == tkIdent and ts[1].word == "b"

  test "unterminated block comment":
    try:
      discard lexAll("-/ no end")
      check false
    except LidwError as e:
      check e.kind == lekLex
      check "unterminated block comment" in e.msg

  test "adjacent dashes are comment, spaced dashes are minus":
    let ts = lexAll("a - -b")
    check ts.len == 5
    check ts[0].kind == tkIdent
    check ts[1].kind == tkMinus
    check ts[2].kind == tkMinus
    check ts[3].kind == tkIdent
    check ts[4].kind == tkEOF

  test "adjacent dash-slash is comment, spaced is minus slash":
    let ts = lexAll("a - / b")
    check ts[0].kind == tkIdent
    check ts[1].kind == tkMinus
    check ts[2].kind == tkSlash
    check ts[3].kind == tkIdent
