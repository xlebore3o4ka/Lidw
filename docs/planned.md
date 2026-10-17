# Planned

What has not been started. For what currently works, see the other
documents in this folder.

## `return`

Early exit from a function body. Sema will require `return` only
inside a function body, and will reject statements after `return`.
`Nul`-returning functions become viable once `return` exists
(`Nul(Int a) log = (print(a); return)`).

## `print`

No output primitive exists. Every program's result is the value of
`main`, which the shell sees as an exit code (mod 256). `print`
likely lands first with integer arguments only, before strings
exist.

## Overflow checks

`add/sub/mul` use LLVM wrap semantics silently at runtime. Planned:
`llvm.sadd.with.overflow` and a panic-on-overflow path. Sema
already rejects literal overflow at compile time.

## Division by zero

Runtime `x/0` is LLVM UB today. Planned: compare against 0 and
panic. Sema rejects literal `1/0`.

## Alloca placement

Alloca goes in the current basic block. Once loops exist this must
move to the function entry block; otherwise a loop body re-allocs
on every iteration.

## Function values

`Int(Int) g = f` typechecks, but assigning a function to a variable
and calling it through the variable is not implemented. Requires
function pointers in codegen (LLVM `ptr` + indirect call).

## Strings

No string type, no string literals. `print` of a string, string
concatenation, etc., are blocked on designing a memory model
(allocation, ownership, GC).

## Loops

No `while`, no `for`. Recursion is the only looping mechanism.
Loops likely need `break`/`continue` and `return`, and a
`while`-as-expression design.

## Comments

Already supported: `--` to end of line, `-/ ... /-` nesting block.
See [syntax.md](syntax.md).
