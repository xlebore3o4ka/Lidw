# TODO / ideas

Not bugs, not committed plans. If any of these becomes important,
it graduates to `issues/` or to a design session.

- **`s$` as reference alias, not a no-op mutability marker.** Today
  `Int b$ = a` is just an explicit-mutable declaration (`muMutable`,
  same as bare `Int b`); it allocates a fresh slot and copies. The
  intended semantics is a **reference alias** to an existing
  variable:

  ```
  Int a = 10
  Int b$ = a
  b = 5
  print(a)   -- 5
  ```

  Rules sketched: RHS must be a mutable lvalue (ident bound to a
  mutable variable; eventually also a call whose return type is
  mutable). Codegen: `alloca ptr`, `store @a`, all `b` reads and
  writes go through the pointer. `b` has type `Int` but no storage
  of its own; rebinding `b` (`b = c`) either writes through or is
  disallowed (TBD). Interaction with shadowing, `break`/`continue`
  inside loops, and passing `b` to `$`-params needs design. Defer
  until pointers and aliasing are on the table; keep `$` as an
  explicit-mutable marker for now.



- **`break expr` for value-loops.** `while` yields `Bool` today
  (`true` = break, `false` = cond-false). `break expr` would make
  the loop yield `expr`'s type when any branch uses `break expr`,
  and reject mixing bare `break` with `break expr` in one loop.
  Defer until value-loops are needed; `(while ...; is result)`
  covers most cases.


- **`for` loop.** Sugar over `while`. Needs either a `Range` type
  (`for i in 0..10`) or a LIDW-idiomatic alternative. Defer until
  Range exists.
- **Implicit "last value" for `while`.** Rejected design: silently
  return the last evaluated expression of a loop body. Do not
  resurrect; `is` and post-loop reads are enough.
- **`print(Bool)`, `print(narrow)`.** Currently require
  `x as Int`. Small quality-of-life; add when it hurts.
- **`print2(Int, Int)` / multi-arg `print`.** Non-variadic
  alternative: `print2(a, b)`, `print3(a, b, c)`. Cheap; the hard
  part is variadic.
- **`extern` declarations + C runtime.** Tracked in
  `issues/002-c-bindings.md`.
- **LLVM target triple + data layout.** Tracked in
  `issues/001-llvm-target-triple.md`.
- **`while` in value position via `if`.** `Int x = if c (while ...;
  is y) else 0` — works already through `is`. Not a feature request.
