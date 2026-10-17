# Blocks and scope

## Grouping vs block

The same parentheses play two roles:

- **Grouping** — one statement inside `( )`. The statement is returned
  unchanged; no new scope.
- **Block** — two or more statements inside `( )`. New scope.

```
(1 + 2)         # grouping: just binOp(+)
(1 + 2; 3)      # block: stmts [binOp(+), nkInt(3)]
```

A block's yield is `Nul` unless it contains `is`, or unless it is
used as a declaration initializer with `is`. Without `is` under a
declaration context, sema reports `block has no value`.

## Scope

A block opens a new scope. Names declared inside are not visible
outside:

```
(Int y = 10 y)   # y is local
y                # sema error: undefined variable: y
```

Outer names are visible inside:

```
Int x = 10
(Int y = 20 x + y)   # ok, x from outer scope
```

## `is` in a block

`is expr` yields `expr` from its innermost enclosing block:

```
Int x = (Int y = 10; is y)     # x = y, x : Int
(1; is 2)                      # block [iLit(2)]
```

Rules enforced by sema:

- `is` must be inside a real block. `(is 1)` works; `is 1` at the
  program root fails with `is outside block`.
- `(is 1)` is *always* parsed as a block, not grouping, so `is` has
  a block to yield from.
- A block yields the type of `is`'s argument. Under a declaration
  context, it must fit `ctx`:
  ```
  Int x = (is 5)         # ok, block yields iLit(5) fits i64
  Bool b = (is 5)        # sema error: iLit(5) does not fit Bool? no —
                         # iLit fits Bool (5 is true); block yields true
  ```
- Statements after `is` in the same block are unreachable and
  rejected: `(is 1; 2)` → `unreachable statement after is`.

## `if` branches are not blocks

An `if` branch accepts a single expression:

```
if c 1 else 0
```

To use `is` inside a branch, wrap in parentheses so the branch
becomes a block:

```
Int x = if c; (is 1); else; (is 2)     # ok
Int x = if c; is 1; else; is 2         # sema error: is outside block
```

## Root program

The whole program is a `nkProgram` node, not an `nkBlock`. Its type
is `Nul`. Differences from a block:

- No yield scope for `is`: `is 1` at the top level is an error.
- The root scope holds top-level declarations, closed at program end.

Declarations inside execute in order; no `main` function.

## Codegen scope

The codegen mirrors the sema scope model with a stack of name
tables. A block opens a new table. A declaration shadows an outer
name by creating a fresh `alloca`; after the block closes, the
outer alloca is visible again. LLVM auto-renames duplicate alloca
names in printed IR (`%x`, `%x1`, `%x2`). See
[codegen.md](codegen.md).
