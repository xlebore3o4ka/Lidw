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

## Codegen follow-ups

See [codegen.md](codegen.md) for what currently works. Follow-ups
not yet started:

- **Overflow checks.** `add/sub/mul` currently wrap silently at
  runtime. Planned: LLVM `sadd.with.overflow` intrinsics and a
  `panic`-on-overflow path.
- **Division by zero.** Runtime `x/0` is LLVM UB today. Planned:
  compare against 0 and panic.
- **`print`.** Needed to replace the temporary "`main` returns the
  last value" scaffold (TODO#39) with real program semantics.
- **Alloca placement.** Alloca goes in the current block. Once
  loops exist this must move to the function entry block
  (TODO#41).

## Strings, chars

No string or char literals.

## Floats

Float literals parse (`3.14` → `tkFloat`), but the type system has
no float type. `lidw check` on a float expression does not assign a
type.
