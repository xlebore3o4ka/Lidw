# Overflow, division, panic

Runtime arithmetic in LIDW can abort the program via `panic`. This
file covers what is checked, what is not, and what `panic` does.

## `panic()`

Builtin `Nul()`. Lowers to `llvm.trap` followed by `unreachable`.
The trap instruction is `ud2` on x86; the process dies with SIGILL
(exit code 132 under a shell). No return value.

```
panic()                       -- statement
Int(Int a) f = (if a < 0 panic(); is a)
```

`panic` is a builtin like `print`: sema sees it as an ordinary
`Nul()` symbol in the root scope. A user declaration of `panic` in
the program scope shadows it, and codegen calls the user's function
instead of the trap.

`panic()` in value position is a sema error (`Nul` does not fit any
value type).

## Checked: signed arithmetic

For `i8/i16/i32/i64`:

| Operator | Check                          | Action  |
|---------:|--------------------------------|---------|
| `+`      | `lhs + rhs` overflows          | `panic` |
| `-`      | `lhs - rhs` overflows          | `panic` |
| `*`      | `lhs * rhs` overflows          | `panic` |
| `/`      | `rhs == 0`                     | `panic` |
| `/`      | `lhs == INT_MIN && rhs == -1`  | `panic` |
| `%`      | `rhs == 0`                     | `panic` |
| `%`      | `lhs == INT_MIN && rhs == -1`  | `panic` |

Checked operations lower to `llvm.<sadd|ssub|smul>.with.overflow.iN`
and `br` on the overflow flag. Each check adds two basic blocks
(`arith.panic`/`arith.cont`, `div.panic1`/`div.ok1`, etc.).

## Not checked: unsigned arithmetic

For `u8/u16/u32/u64`:

| Operator | Behavior |
|---------:|----------|
| `+ - *`  | wrap (two's complement) |
| `/ %`    | check `rhs == 0` only, no wrap issue |

Unsigned wrap is a legitimate value transformation (hashing, bit
manipulation), so it is not a panic. Divide-by-zero is still an
error.

## Not checked: conversions

`as` (cast) is not a checked operation:

```
Int v = 300
U8 x = v as U8        -- truncates to 44, no panic
```

Sema already rejects literal overflow (`U8 x = 300` is an error at
compile time). Cast is the explicit "I know what I am doing" way to
force a value into a narrow type.

## Not checked: literal arithmetic

Sema folds literal-only expressions:

```
Int x = 9223372036854775807 + 1
```

`sema error: integer overflow: 9223372036854775807 + 1`

This is a compile error, not a runtime panic.

## Disabling checks

`emitModule` accepts an `overflowChecks: bool` parameter (default
`true`). The `lidw build` CLI does not expose it yet; a future
`--release` / `--no-overflow-checks` flag will. Unit tests that
build AST by hand pass `false` because they only exercise codegen
shapes, not runtime.

## See also

- [expressions.md](expressions.md) — operator precedence and typing
- [functions.md](functions.md) — builtins (`print`, `panic`)
- [codegen.md](codegen.md) — how checked arithmetic lowers to IR
