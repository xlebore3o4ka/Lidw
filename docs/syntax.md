# Lexical syntax

## Identifiers

An identifier starts with `A-Z`, `a-z`, or `_`, and continues with
letters, digits, and `_`. ASCII only; no unicode identifiers.

Case determines role:

| First char        | Token kind | Meaning           |
|-------------------|------------|-------------------|
|  `A`–`Z`          | `tkType`   | type name         |
|  `a`–`z`, `_`     | `tkIdent`  | variable, keyword |

No exceptions: `Int` is a type, `int` is an identifier, `If` is a
type, `if` is a keyword. `_x` is an identifier, `X_` is a type.

## Keywords

Reserved (lowercase only; uppercase forms stay `tkType`):

- `if`
- `elif`
- `else`
- `is`
- `as`

Not reserved: `fn`, `func`, `def`, `return`, `let`, `var`. Functions
use type expressions (`Int(Int a) f = ...`) instead of a keyword.

No other reserved words. `iff`, `elsewhere`, `issue` are plain
identifiers. `true`/`false` are not keywords — see
[types.md](types.md).

## Literals

- **Integer:** one or more ASCII digits. Value is `int64`. `42`, `0`,
  `9223372036854775807`. Value overflow is a lex error.
- **Float:** digits `.` digits. Parsed into a float value; sema does
  not support float types yet, so `lidw check` on a float expression
  fails downstream.
- No string, char, or boolean literals. `Bool` values come from
  `iLit` fitting into a `Bool` context, or from comparisons.

## Operators and punctuation

| Symbol | Token          | Meaning                         |
|-------:|----------------|---------------------------------|
|  `+`   | `tkPlus`       | addition                        |
|  `-`   | `tkMinus`      | subtraction / unary negation    |
|  `*`   | `tkStar`       | multiplication                  |
|  `/`   | `tkSlash`      | integer division                |
|  `%`   | `tkPercent`    | modulo                          |
|  `==`  | `tkEqEq`       | equality                        |
|  `!=`  | `tkBangEq`     | inequality                      |
|  `<`   | `tkLt`         | less-than                       |
|  `<=`  | `tkLe`         | less-or-equal                   |
|  `>`   | `tkGt`         | greater-than                    |
|  `>=`  | `tkGe`         | greater-or-equal                |
|  `=`   | `tkEquals`     | assignment / declaration init   |
|  `(`   | `tkLParen`     | grouping / block open           |
|  `)`   | `tkRParen`     | grouping / block close          |
|  `;`   | `tkSemicolon`  | optional statement separator    |
|  `!`   | `tkBang`       | postfix: immutable declaration  |
|  `$`   | `tkDollar`     | postfix: explicit mutable       |

Two-character operators are greedy: `!=` is one token when `!` and
`=` are adjacent. Whitespace matters:

```
x != y       -- tkBangEq, one token
x! = y       -- tkBang, tkEquals
```

## Whitespace and separators

Whitespace separates tokens and is otherwise ignored. Statement
boundaries are inferred: a statement ends where the next token
cannot continue the current expression.

`;` is an optional explicit separator. It is required only where
inference is ambiguous, typically before a unary operator:

```
Int x = 5 -x       -- parsed as Int x = (5 - x); x is undefined -> error
Int x = 5; -x      -- two statements: Int x = 5, then -x
```

Trailing `;` in a block or program is allowed. Empty statements
(`;;;`) are allowed at the top level.

## Parentheses

`( stmt )` with one statement is *grouping*: the statement is
returned unchanged, no new scope.

`( stmt; stmt; ... )` with two or more is a *block*: new scope,
statement body. See [blocks.md](blocks.md).

`( is expr )` is *always* a block, because `is` needs a block to
yield from.

`()` is a parse error.

## Comments

Two forms, both consumed as trivia (like whitespace):

- **Line comment:** `--` to end of line.
  ```
  Int x = 1 -- set to one
  ```
- **Block comment:** `-/` to `/-`. May span lines. Nests.
  ```
  -/ outer
     -/ inner /-
     still outer /-
  Int x = 1
  ```

A nested `-/` opens another level; the matching `/-` closes only
that level. `-/ -/ x /- /-` is a single comment.

**Adjacency matters.** The two-char sequences must be next to each
other:

- `a - -b` is subtraction of unary minus. `a--b` is `a` followed by
  a line comment (the `-b` is gone).
- `a -/ b` opens a block comment. `a - / b` is minus then slash, a
  parse error in most contexts.

An unterminated block comment is a lex error. A line comment ends
at EOF (or at `\n` / `\r`).
