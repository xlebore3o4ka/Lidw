# Planned and in-progress

What exists in the tree but is not fully functional, and what has
not been started.

## In progress

### `if` / `elif` / `else`

**Parser:** ready.

**Syntax:**

```
if cond stmt
if cond stmt else stmt
if cond stmt elif cond stmt else stmt
```

`;` is allowed but not required:

```
if 1 > 0; x = 1; else x = 0
```

`elif` desugars to a nested `if` in the `else` branch. Dangling
`else` binds to the nearest `if`.

`else` is optional. Without it, the false branch yields the default
of the branch's type (once sema is implemented).

**Sema:** not yet. `lidw check 'if 1 1 else 0'` returns
`sema error: if: not implemented yet`.

### `is`

**Parser:** ready.

**Syntax:** `is expr`.

`is` yields a value from its innermost enclosing block and terminates
that block. Any statements after `is` in the same block are
unreachable (once sema is implemented, they will be an error).

**Sema:** not yet. `lidw check '(is 1)'` returns
`sema error: is: not implemented yet`.

## Not started

### Functions

Planned shape: a function type `T(A, B)` and calls `f(x, y)`.
Mutability postfix `$` on parameters marks mutable arguments:

```
Int(Int a$) f      # a is passed by reference and may be mutated
```

Not implemented in any layer.

### Codegen

No compilation target yet; everything is frontend. When codegen
exists, it will handle:

- Default values (`Int` → 0, `Bool` → false) for uninitialized
  declarations.
- Comparison evaluation (`1 < 2` → true at runtime; currently a
  `Bool` node without a value).
- Block yields (currently `nul`).

### Comments

No comment syntax yet. No `//`, no `/* */`, no `#`.

### Strings, chars

No string or char literals.

### Floats

Float literals parse (`3.14` → `tkFloat`), but the type system has
no float type. `lidw check` on a float expression does not assign a
type.
