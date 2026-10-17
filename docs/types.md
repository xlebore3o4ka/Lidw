# Type system

## Integer types

Eight fixed-width integer types. `Int` is an alias for `I64`.

| Type | Width | Range                       |
|------|------:|-----------------------------|
| I8   |     8 | -128 .. 127                 |
| U8   |     8 | 0 .. 255                    |
| I16  |    16 | -32768 .. 32767             |
| U16  |    16 | 0 .. 65535                  |
| I32  |    32 | -2147483648 .. 2147483647   |
| U32  |    32 | 0 .. 4294967295             |
| I64  |    64 | -2^63 .. 2^63-1             |
| U64  |    64 | 0 .. 2^64-1                 |

There is no implicit conversion between concrete integer types:
`U8` does not fit `U16`, `I8` does not fit `I32`. Widening happens
only inside binary operators (see [expressions.md](expressions.md)).
`U64` literals above `2^63-1` cannot be written in source yet;
`iLit` carries `int64`.

To move a value between types, use an explicit cast `as`:

```
U8 x = 5
U16 y = x          -- sema error: initializer of y has type u8, expected u16
U16 z = x as U16   -- ok, explicit cast
```

## Bool

`true` / `false`. No literals in the language. A `Bool` value comes
from one of two places:

1. An integer literal fitting into a `Bool` context:
   `Bool b = 1` -> true, `Bool b = 0` -> false. Non-zero is true.
2. A comparison result: `Bool b = 1 < 2`, `Bool b = x == 0`.

An `Int` variable does not fit into `Bool` implicitly. Convert
explicitly: `v as Bool` (non-zero -> true), or compare `v != 0`.

## Nul

"No value". The type of an expression in statement position, and of
`if` without a value context.

`Nul` is not a user-writable type name; it appears only in sema
output (`[nul]`).

```
if 1 1 else 0        -- if [nul] (statement)
(1 2)                -- block [nul] (no is)
```

`Nul` fits only into `Nul`. It does not fit into any Int kind, Bool,
or anything else:

```
Int x = (1 2)        -- sema error: block has no value, expected i64
(1 2) + 1            -- sema error: cannot unify nul and iLit(1)
```

## The literal type `iLit(N)`

An integer literal in source does not have a concrete type yet. It
carries its value and fits into any concrete type whose range
contains it.

`iLit(N)` fits into:

- **`I8`** iff `N` in `-128 .. 127`.
- **`U8`** iff `N` in `0 .. 255`.
- **`I16`, `U16`, `I32`, `U32`** — analogous per-width ranges.
- **`I64`** — always (value is `int64`).
- **`U64`** iff `N >= 0`.
- **`Bool`** — always (0 is false, non-zero is true).
- **`iLit(M)`** iff `N == M`.

`iLit(N)` does not fit into `Nul`.

`iLit` is not user-visible as a type name. It appears in `lidw check`
output as `iLit(42)`. It exists to keep literal values precise
through sema, so that folding like `1 + 2 -> iLit(3)` and overflow
detection work.

## `fits(t, expected)`

`fits(t, expected)` decides whether a value of type `t` can be used
where `expected` is required.

|         | int k              | Bool              | Nul  | iLit(M)   |
|---------|:------------------:|:-----------------:|:----:|:---------:|
| int j   |  j == k            |        ✗          |  ✗   |     ✗     |
| Bool    |        ✗           |        ✓          |  ✗   |     ✗     |
| Nul     |        ✗           |        ✗          |  ✓   |     ✗     |
| iLit(N) | `fitsIntLit(N, k)` | non-zero -> true  |  ✗   | iff N == M |

`fits` is a **check**, not a coercion. A literal that fits into a
concrete int stays `iLit(N)` in the AST. Only the surrounding
operation (decl, comparison, assignment, branch) gets the concrete
type.

## Type resolution

`resolveTypeName(name, line, col)` maps a `tkType` token's text to a
`LidwType`:

- `"Int"`, `"I64"` -> `i64`
- `"I8"`, `"U8"`, `"I16"`, `"U16"`, `"I32"`, `"U32"`, `"U64"` ->
  matching kind
- `"Bool"` -> `Bool`
- anything else -> sema error `unknown type: <name>`

`Nul` is not resolvable. User code cannot declare a `Nul` variable.
