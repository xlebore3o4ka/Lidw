# TODO / ideas

Not bugs, not committed plans. If any of these becomes important,
it graduates to `issues/` or to a design session.


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
