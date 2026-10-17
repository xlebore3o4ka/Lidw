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

A block's yield is `nul` unless it contains `is` (see
[planned.md](planned.md)) or is used as a declaration initializer.
Under a declaration initializer without `is`, sema reports
`block has no value`.

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

`is expr` yields a value from its innermost enclosing block. Parsing
is implemented; sema is not yet (see [planned.md](planned.md)).

Parentheses are not required if `is` appears directly in a block body:

```
(x is 1)               # block with one stmt `is 1` (kept as block)
if c; is 1; else; is 2
```

`( is 1 )` is *always* parsed as a block, not grouping, so `is` has a
block to yield from.

## Root program

The whole program is a block (statement sequence). Its type is `Nul`.
Declarations inside execute in order; no `main` function.
