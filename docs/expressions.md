# Expressions

## Literals

| Source    | AST node  | Type before sema |
|-----------|-----------|------------------|
| `42`      | `nkInt`   | `iLit(42)`       |
| `3.14`    | `nkFloat` | `nil` (no float type yet) |

Float literals are parsed but sema does not assign them a type.

## Identifiers

`x` reads the current binding of `x`. Type is the binding's type.
Undefined name → sema error.

## Unary operators

```
-expr
```

Unary minus. Operand must be `Int` or `iLit`. Result:

- `iLit(N)` → `iLit(-N)`, with overflow check on `-low(int64)`.
- `Int` variable → `Int`.
- Anything else (`Bool`, `Nul`) → sema error.

## Binary arithmetic

```
a + b    a - b    a * b    a / b    a % b
```

Precedence (higher binds tighter):

| Level | Operators         | Associativity |
|------:|-------------------|---------------|
|   3   | `* / %`           | left          |
|   2   | `+ -`             | left          |
|   1   | `< <= > >= == !=` | left          |

All binary operators are left-associative: `1 - 2 - 3` is `(1-2)-3`.

Operand rules (context-less):

- `iLit + iLit` folds: `1 + 2` → `iLit(3)`. Overflow and division by
  zero are sema errors at this point.
- Two concrete integers of the same kind → that kind:
  `Int + Int → Int`, `U8 + U8 → U8`.
- Both signed, or both unsigned, different widths → the wider kind:
  `I8 + I16 → I16`, `U8 + U16 → U16`.
- Mixed signed/unsigned → smallest signed kind that holds both:
  `U8 + I8 → I16`, `U16 + I16 → I32`, `U32 + I32 → I64`.
  `U64 + I64` has no common type; sema error.
- `iLit(N)` with a concrete kind adapts if `N` fits; otherwise sema
  error. Example: `U8 x = 5; x + 200` is ok, `x + 300` is not.
- `Bool` operand → sema error `arithmetic requires Int`.
- `Nul` operand → sema error.

Under a declared context (`Int x = ...`), the top-level expression is
checked against the expected type. Folding still happens for literals:
`Int x = 1 + 2` gives `x : Int` initialized by `iLit(3)`, not by
`Int` arithmetic.

## Comparison

```
a == b    a != b    a < b    a <= b    a > b    a >= b
```

Result type: `Bool`.

Operand rules:

| Operator    | Left          | Right         |
|-------------|---------------|---------------|
| `==`, `!=`  | `Int`         | `Int`/`iLit`  |
| `==`, `!=`  | `Bool`        | `Bool`/`iLit` |
| `==`, `!=`  | `iLit`        | `Int`/`Bool`  |
| `< <= > >=` | `Int`/`iLit`  | `Int`/`iLit`  |

Mixing `Int` and `Bool` in one comparison is a sema error.

Comparisons do **not** fold. `1 < 2` produces a `Bool`-typed node
without a stored value. Codegen (not implemented) will compute it.

## Cast: `as`

```
expr as Ty
```

Explicit cast. `Ty` is a `tkType` token (uppercase first letter).
Precedence: binds tighter than binary operators, looser than unary:

```
-x as U8       -- (-x) as U8
2 * 5 as U8    -- 2 * (5 as U8)
```

Chained left to right: `x as Int as Bool`.

Source must be a value (Int, Bool, or `iLit`). `Nul` cannot be cast.
Target must be a known type name (`Int`, `U8`, `Bool`, ...). The
cast is explicit; there is no `fits`-check on the source. Values
wrap (truncate) and extend by source signedness:

```
Int v = 300
U8 x = v as U8        -- x = 44   (truncate)
Bool b = v as Bool    -- b = true (v != 0)
Int back = b as Int   -- back = 1
U8 y = 300 as U8      -- y = 44   (literal folded at U8 width)
```

The result type is the target. As a value, the cast is checked
against `ctx` like any other expression: `Int z = (5 as U8)` is a
sema error because `U8` does not fit `Int`.

## Assignment

`ident = expr` assigns `expr` to `ident`. The target must be bound to
a mutable variable in scope.

Assignment is an expression: its value is the value of `expr`. This
makes it usable where an expression is expected:

```
Int(Int a$) f = a = 1              -- fn body is an assignment; returns 1
Int x = 0 Int y = 0 x = y = 5      -- right-assoc: both end up 5
Int x = 0 (x = 5) + 1              -- value of x=5 is 5; result 6
```

Precedence: assignment is the loosest, below binary operators.
Right-associative: `a = b = c` parses as `a = (b = c)`.

The target must be a bare identifier. `a + 1 = 2` is a parse error
(nothing to assign to). `f(x) = 5` is a parse error for the same
reason.

## Function types and calls

`T(A, B)` is a function type: takes `A` and `B`, returns `T`. It is
usable in declaration position:

```
Int(Int a) f = a + 1
Int(Int a, Int b) add = a + b
U8(U8 a) inc = a + 1
```

Parameters may be named (`Int a`), unnamed (`Int`), or marked
mutable with `$` (`Int a$`). A function declaration is a regular
declaration; the body is a single expression checked against the
return type. See [functions.md](functions.md).

Call is postfix `f(args)`. Zero arguments allowed: `f()`. Trailing
comma tolerated. The callee must resolve to a function type; calling
an `Int` is a sema error.

Precedence, loosest to tightest: binary operators < `as` < unary `-`
< call `(...)` < primary. So:

- `-f(1)` is `-(f(1))`.
- `-1 as U8` is `(-1) as U8`.
- `f(1) as U8` is `(f(1)) as U8`.

## `if` / `elif` / `else`

`if` is an expression. It can appear as a statement or as the value
of a declaration. A branch without parentheses is exactly one
statement; a multi-statement branch must be an explicit `( ... )`
block.

```
if cond stmt
if cond stmt else stmt
if cond stmt elif cond stmt else stmt
```

`;` is allowed but not required:

```
if 1 > 0; x = 1; else x = 0
Int x = if 1 > 0; 1; else 0
```

`elif` desugars to a nested `if` in the `else` branch. Dangling
`else` binds to the nearest `if`; use parentheses to override:

```
if (1) (if (2) 3 else 4) else 5
```

**Condition.** Must fit `Bool`. `iLit` fits (`0` is false).

**Branches.** Each branch is one expression or a parenthesized
block. Under a declaration context (`Int x = if ...`), both branches
must fit `ctx`, and `if` takes `ctx`. In statement position (no
context), `if` is `Nul`; branch results are evaluated for side
effects and discarded. No unify is attempted.

`else` is optional. Without it, the false branch yields default of
the branch's type (once codegen exists).

**Branch bodies and `is`.** A branch is not a block by itself. To
make a branch return a non-default value, wrap it in parentheses so
it becomes a block, and yield via `is`:

```
Int x = if c; (is 1); else; (is 2)     -- ok
Int x = if c; is 1; else; is 2         -- sema error: is outside block
```

**Codegen.** Statement `if` emits `br i1` into `then`/`else`/`merge`
blocks. Value `if` additionally emits a `phi` in `merge`. See
[codegen.md](codegen.md).

## `is`

`is expr` yields `expr` from its innermost enclosing block and
terminates that block.

```
(1; is 2)                          -- block yields iLit(2)
(Int y = 10; is y)                 -- block yields i64
Int x = (Int y = 10; is y)         -- x = y
```

- `is` must be inside a block. On the program root or directly in an
  `if` branch → `is outside block`.
- Statements after `is` in the same block → `unreachable statement
  after is`.
- `(is expr)` is *always* parsed as a block, so `is` has a block to
  yield from.

**Codegen.** A value-block emits its statements in a new scope
(names don't collide with outer block) and returns the value of
`is`. See [codegen.md](codegen.md).

## `while`

`while cond body` repeats `body` while `cond` fits `Bool`.

```
Int x = 0
while x < 5 x = x + 1
-- x == 5
```

The body follows the `if`-branch rule: without parens it is one
statement; with parens it is a block:

```
while x < 5 x = x + 1
while x < 5 (x = x + 1; print(x))
```

`while` is a statement (yields `Nul`).

Inside a `while` body, `break` exits the innermost enclosing loop:

```
Int x = 0
while 1 (if x >= 3 break; x = x + 1)
-- x == 3
```

`break` is terminal: statements after it in the same block are
unreachable. `continue`, `break expr`, and `for` are not yet (see
[TODO.md](../TODO.md)).

**Pitfall.** `if j > i (break)` parses as `if j > (i(break))`
because `i` is callable and `(` triggers a call. Drop parens around
the if-body (`if j > i break`) or avoid ending the condition with a
callable. Proper adjacency fix for `(` is tracked in `TODO.md`.

`ret` inside a `while` exits the enclosing function, not the loop.


## `ret`

`ret` exits the current function. It is a statement, not an
expression. `ret expr` returns a value; bare `ret` returns the
default of the return type (`0`, `false`, or nothing for `Nul`).
See [return.md](return.md). Use `is` (not `ret`) to yield from a
block.

## Grouping


`( expr )` groups:

```
(1 + 2) * 3     -- iLit(9)
```

See [blocks.md](blocks.md) for `( stmt; stmt )`.

## Examples

```
10 + 4                              -- iLit(14)
(10 + 4) * 5                        -- iLit(70)
1 + 2 * 3                           -- iLit(7)
-(1 + 2)                            -- iLit(-3)
1 < 2                               -- Bool (no value)

Int x = 10
x + 1                               -- Int
x == 10                             -- Bool

Bool c = 1
Int y = if c 10 else 20             -- if [i64]
if x < 5 x = 10 else x = 20         -- if [nul], statement
Int z = if c; (is 5); else; (is 7)  -- if [i64]
```
