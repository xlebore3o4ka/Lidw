# Planned

What has not been started. For what currently works, see the other
documents in this folder.

## Functions

Planned shape: a function type `T(A, B)` and calls `f(x, y)`.
Mutability postfix on parameters marks mutable arguments (specific
marker TBD; `$` was removed from declarations in an earlier step
because it was a no-op).

```
Int(Int a) f = a + 1        # f takes Int, returns Int
f(10)                       # Int
```

Layers to implement:

- Type expressions: `T(A, B)` in type position, in addition to the
  current single-token type names. Resolve to `tyFn(params, ret)`.
- Function declarations: `nkFn` node with name, param names, param
  types, return type, body expression.
- Calls: `nkCall(fn, args)`. Parser distinguishes call `f(...)` from
  grouping `(...)`.
- Sema: `Symbol` for functions; parameter binding; arg-fit; body
  fit to return type; recursion.
- Forward references: not yet decided (declare-before-use like C,
  or multi-pass).

## Codegen

No compilation target yet; everything is frontend. When codegen
exists it will handle:

- Default values (`Int` → 0, `Bool` → false) for uninitialized
  declarations.
- Comparison evaluation (`1 < 2` → true at runtime; currently a
  `Bool` node without a value).
- Block yields via `is` (currently typed, not evaluated).
- `if` without `else` fills the missing branch with default of
  `ctx`.

## Comments

No comment syntax yet. No `//`, no `/* */`, no `#`.

## Strings, chars

No string or char literals.

## Floats

Float literals parse (`3.14` → `tkFloat`), but the type system has
no float type. `lidw check` on a float expression does not assign a
type.
