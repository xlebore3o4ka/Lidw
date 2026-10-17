# Type system

## User-facing types

### `Int` (alias `I64`)

64-bit signed integer. Range `-2^63` to `2^63 - 1`.

### `Bool`

`true` / `false`. No literals in the language. A `Bool` value comes
from one of two places:

1. An integer literal fitting into a `Bool` context:
   `Bool b = 1` → true, `Bool b = 0` → false. Non-zero is true.
2. A comparison result: `Bool b = 1 < 2`.

`Int` variables do not fit into `Bool` implicitly. Convert explicitly
with `x == 0` or `x != 0`, not `Bool b = x`.

### `Nul`

"No value". The type of a statement that produces nothing. `Nul` is
not a user-writable type name; it appears only in sema output.

A block without `is` and outside an expected type yields `Nul`.

`Nul` fits only into `Nul`. It does not fit into `Int`, `Bool`, or
anything else. So `Int x = (1 2)` is a sema error, and `(1 2) + 1`
is a sema error.

## The literal type `iLit(N)`

An integer literal in source does not have a concrete type yet. It
carries its value and fits into any concrete type that can hold it.

`iLit(N)` fits into:

- **`Int`** — always (the value is already `int64`).
- **`Bool`** — always (0 is false, non-zero is true).
- **`iLit(M)`** — only if `N == M`.

`iLit(N)` does not fit into `Nul`.

`iLit` is not user-visible as a type name. It appears in `lidw check`
output as `iLit(42)`. It exists to keep literal values precise
through sema, so that folding like `1 + 2 → iLit(3)` and overflow
detection work.

## `fits(t, expected)`

`fits(t, expected)` decides whether a value of type `t` can be used
where `expected` is required.

|         | Int  | Bool | Nul  | iLit(M)   |
|--------:|:----:|:----:|:----:|:---------:|
| Int     |  ✓   |  ✗   |  ✗   |     ✗     |
| Bool    |  ✗   |  ✓   |  ✗   |     ✗     |
| Nul     |  ✗   |  ✗   |  ✓   |     ✗     |
| iLit(N) |  ✓   |  ✓   |  ✗   | iff N == M |

`fits` is a **check**, not a coercion. A literal that fits into `Int`
stays `iLit(N)` in the AST. Only the surrounding operation (decl,
comparison, assignment) gets the concrete type.

## Type resolution

`resolveTypeName(name, line, col)` maps a `tkType` token's text to a
`LidwType`. Currently:

- `"Int"`, `"I64"` → `Int`
- `"Bool"` → `Bool`
- anything else → sema error `unknown type: <name>`

`Nul` is not resolvable. User code cannot declare a `Nul` variable.
