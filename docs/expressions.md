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
- `Int` with `Int` → `Int`.
- `Int` with `iLit`, or `iLit` with `Int` → `Int`; the literal is
  checked to fit `Int`.
- `Bool` operand → sema error `cannot unify ...`.
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

## Grouping

`( expr )` groups:

```
(1 + 2) * 3     # iLit(9)
```

See [blocks.md](blocks.md) for `( stmt; stmt )`.

## Examples

```
10 + 4          # iLit(14)
(10 + 4) * 5    # iLit(70)
1 + 2 * 3       # iLit(7)
-(1 + 2)        # iLit(-3)
1 < 2           # Bool (no value)
Int x = 10
x + 1           # Int
x == 10         # Bool
```
