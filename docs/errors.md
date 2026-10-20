# Errors

One type: `LidwError` with `kind`, `line`, `col`. Messages go to
stderr as `<kind> error: <msg> at <line>:<col>`. Exit code is 1 for
`LidwError`, 2 for internal errors.

## Lex errors (`lekLex`)

- `unexpected character '<ch>'` — a byte no token starts with.
  Cyrillic and other non-ASCII input hits this.
- `unterminated block comment` — `-/` without a matching `/-`.

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

### Names and declarations

- `undefined variable: <name>` — name read before it is declared.
- `unknown type: <name>` — `resolveTypeName` has no alias for it.
- `redeclaration of <name> (previously declared at L:C)` — same
  scope.
- `cannot assign to immutable variable <name>` — write to `x!`.
- `initializer of <name> has type <got>, expected <type>` — value
  does not fit declared type.
- `cannot assign <got> to <type> variable <name>` — assignment
  type mismatch.

### Blocks and `is`

- `block has no value, expected <type>` — block without `is` in
  value position.
- `block yields <type>, expected <type>` — `is`-value in block does
  not fit the declaration context.
- `is outside block (use ...)` — `is` at program root, or directly
  in an `if` branch without parentheses.
- `unreachable statement after is` — any statement after `is` in
  the same block.

### Functions

- `function declarations are only allowed at program top level` —
  fn decl inside a block.
- `function declaration requires a body: <name>` — `Int(Int a) f`
  without `=`.
- `Nul-returning functions not implemented yet` — `Nul` return type.
- `parameter must be named (use `Int()` for no parameters)` — a
  function declaration has an unnamed parameter. Use a name, or drop
  the parameter entirely for zero-arg functions.
- `body of <name> has type <got>, expected <type>` — body value does
  not fit the return type.

### Calls

- `cannot call <type>` — callee is not a function type (`x(1)` where
  `x: Int`).
- `call expects N argument(s), got M` — argument count mismatch.
- `argument N has type <got>, expected <type>` — argument type does
  not fit the parameter.
- `argument N must be mutable (ident bound to a mutable variable),
  got a value expression` — a mutable parameter received a literal
  or a computed value.
- `argument N must be mutable, but <name> is immutable` — mutable
  parameter received an immutable variable.

### `break` / `continue`

- `break outside loop` / `continue outside loop` — at program root
  or outside any `while` body.
- `unreachable statement after break` / `unreachable statement after
  continue` — statement after a terminal `break`/`continue` in the
  same block.
- `value `while` (with `break expr`) needs a context; assign it:
  `Int x = while ...`` — a value loop in statement position.
- `break value has type <got>, expected <type>` — `break expr` value
  does not fit the loop's context.
- `break with value in a non-value loop (no `break expr` in
  siblings)` — defensive; should not be reachable, since any
  `break expr` makes the loop a value loop.



### `while`

- `while condition has type <type>, expected Bool` — the condition
  does not fit `Bool`.
- `initializer of <name> has type Bool, expected <type>` —
  `Int x = while ...` where the loop yields `Bool`. Use a `Bool`
  target or discard the result in statement position.


### `discard`

`discard` is a statement; `Int x = discard ...` is a parse error
(`unexpected token: tkDiscard`). Use `discard` at statement level,
or drop the leading `discard` if you actually want the value.

### `ret`


- `ret outside function; use `is` to yield from a block, or declare
  a function with a return type` — `ret` at program root or in a
  plain block.
- `ret value has type <got>, expected <type>` — value does not fit
  the return type.
- `unreachable statement after ret` — statement after a terminal
  `ret` in the same block.
- `unreachable statement after if` — statement after an `if` whose
  every branch returns.
- `ret in if branch used as value; use a block with `is`, or make
  both branches ret` — mixing `ret` and yield in a value-context
  `if`.
- `Nul is a return-only type; use it only as a function return type`
  — `Nul x = ...`.

### `if`


- `if condition has type <type>, expected Bool` — `Int c = 1; if c ...`.
- `if branch yields <type>, expected <type>` — under declaration
  context, one branch does not fit `ctx`.

### Floats

- `float literal <v> does not fit <type>` — `F32 x = 1e40` (out of
  F32 range; currently the lexer only handles `digits.digits`, so
  this requires `1.0 * 1e40` which is not lexable yet).
- `operator % is not defined for Float` — `1.5 % 0.5`.
- `cannot cast Bool to <Float type>` — `Bool -> Float` needs
  `as Int` first.
- `arithmetic requires matching kinds: <t> and <t>` — Int + Float
  without an explicit `as`.

### Operators


- `cannot unify <lt> and <rt> for <op>` — binary operator with
  incompatible operand types.
- `arithmetic requires Int, got <lt> and <rt>` — non-Int operand
  (Bool, Nul) in an arithmetic operator.
- `literal iLit(N) does not fit <type>` — literal not in the target
  range (`U8 x = 5; x + 300`).
- `no common type for <lt> and <rt>` — mixed operands with no Int
  kind that holds both (`U64 + I64`).
- `cannot cast <type>` — `as` on `Nul` or on a future non-value type.
- `cast to <type> does not fit <ctx>` — cast result does not satisfy
  the surrounding declaration context.
- `operator <op> requires Int operands, got <lt> and <rt>` —
  ordering on non-Int.
- `operator <op> requires matching types, got <lt> and <rt>` —
  equality across Int and Bool.
- `comparison result Bool does not fit <type>` — `Int x = 1 < 2`.
- `unary <op> requires Int, got <type>` — `-true`, or `-b` when
  `b` is Bool.
- `integer overflow: <a> <op> <b>` — literal folding overflow.
- `division by zero` — literal folding.

## Runtime panics

These are not `LidwError`. They abort the process via `llvm.trap`
(SIGILL). Each one is traceable to a source line through DWARF
debug info (see [debug.md](debug.md)).

- `panic()` — explicit. The trap is at the source line of `panic()`.
- `+ - *` on signed integers overflow — the trap is at the operator.
- `/ %` by zero — trap at the operator.
- `/ %` on signed `INT_MIN` and `-1` — trap at the operator.

No `panic` is thrown for unsigned `+ - *` overflow; that wraps.

## Runtime panics

These are not `LidwError`. They abort the process via `llvm.trap`
(SIGILL). Each one is traceable to a source line through DWARF
debug info (see [debug.md](debug.md)).

- `panic()` — explicit. The trap is at the source line of `panic()`.
- `+ - *` on signed integers overflow — the trap is at the operator.
- `/ %` by zero — trap at the operator.
- `/ %` on signed `INT_MIN` and `-1` — trap at the operator.

No `panic` is thrown for unsigned `+ - *` overflow; that wraps.

## Internal errors



These are not `LidwError`. They indicate bugs in the compiler
itself, and print as `internal error: <msg>` with exit code 2.

- `codegen: unsupported node: <kind>` — codegen encountered an
  AST node it does not handle yet (e.g. `nkFn` after a future
  feature is added to the parser).
- `codegen: unsupported binop: <op>` — sema passed an operator
  codegen does not know.
- `codegen: undefined variable: <name>` — a name survived sema
  but is not in the codegen symbol table. Should be unreachable.
- `codegen: value block without is` — value-block with no `is`.
  Sema should have caught this.
- `LLVM verify failed: <msg>` — LLVM's own verifier rejected the
  module. Indicates a codegen bug; the message names the malformed
  construct.
