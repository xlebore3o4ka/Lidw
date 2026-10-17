# Errors

One type: `LidwError` with `kind`, `line`, `col`. Messages go to
stderr as `<kind> error: <msg> at <line>:<col>`. Exit code is 1 for
`LidwError`, 2 for internal errors.

## Lex errors (`lekLex`)

- `unexpected character '<ch>'` — a byte no token starts with.
  Cyrillic and other non-ASCII input hits this.

## Parse errors (`lekParse`)

- `expected expression, got type <name>` — `tkType` in expression
  position (`Int x = Int`).
- `unexpected token: <tok>` — operator in the wrong place.
- `expected ')' but got ...` — mismatched parenthesis.
- `empty parentheses` — `()`.
- `expected identifier after type <name>` — `Int = 10`, `Int 10`.
- `unexpected token after expression: <tok>` — trailing tokens.
- `if requires a body`, `else requires a body` — empty branch.
- Adjacent `!` and `=` in a declaration: `Int x!=5` lexes as
  `tkType tkIdent tkBangEq tkInt`, which the parser cannot use.
  Add a space: `Int x! = 5`.

## Sema errors (`lekSema`)

- `undefined variable: <name>` — name read before it is declared.
- `unknown type: <name>` — `resolveTypeName` has no alias for it.
- `redeclaration of <name> (previously declared at L:C)` — same
  scope.
- `cannot assign to immutable variable <name>` — write to `x!`.
- `initializer of <name> has type <got>, expected <type>` — value
  does not fit declared type.
- `cannot assign <got> to <type> variable <name>` — assignment
  type mismatch.
- `block has no value, expected <type>` — block without `is` in
  value position.
- `cannot unify <lt> and <rt> for <op>` — binary operator with
  incompatible operand types.
- `operator <op> requires Int operands, got <lt> and <rt>` —
  ordering on non-Int.
- `operator <op> requires matching types, got <lt> and <rt>` —
  equality across Int and Bool.
- `comparison result Bool does not fit <type>` — `Int x = 1 < 2`.
- `unary <op> requires Int, got <type>` — `-true`, or `-b` when
  `b` is Bool.
- `integer overflow: <a> <op> <b>` — literal folding overflow.
- `division by zero` — literal folding.
