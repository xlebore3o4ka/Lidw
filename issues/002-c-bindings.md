# 002 — C bindings, removing `print` as a special codegen case

**Status:** deferred
**Layer:** sema, codegen, language
**Related:** `print` builtin (see `docs/functions.md#builtins`)

## Problem

`print(Int)` is a builtin with a special codegen path.
`isBuiltinPrint` detects `nkCall(nkIdent "print", ...)` and lowers
it to an inline `printf("%ld\n", x)`. No `@print` symbol exists in
the module. This is the only such special case today; it is debt:

- The user cannot write an equivalent `print` themselves: no extern
  declaration, no string literals, no variadic function types.
- User shadowing works only because codegen checks
  `LLVMGetNamedFunction("print") == nil`, which is a hack, not a
  guarantee.
- Every new builtin (`panic`, `exit`, `malloc`, ...) would add
  another `isBuiltinX` and another codegen branch.

Sema is fine: it sees `print` as an ordinary `Nul(Int)` symbol from
the root scope. Only codegen diverges.

## Fix

Give the language enough rope to declare C functions. Then `print`
stops being special:

1. **Extern declarations** in LIDW source:
   ```
   extern Nul(Int x) print = "print_int_v1"
   ```
   `print` has the given LIDW type; codegen emits a call to the
   symbol `print_int_v1`, provided by a C runtime linked at build
   time. No body required.

2. **A tiny C runtime** in `runtime/lidw.c`:
   ```c
   #include <stdio.h>
   void print_int_v1(long x) { printf("%ld\n", x); }
   ```

3. **`print` becomes an extern** in a synthetic prelude that sema
   injects at program start (like `installBuiltins` today, but as
   real declarations).

4. **Delete `isBuiltinPrint` and the lazy `printf` setup** in
   `src/backend/codegen.nim`. A `print` call becomes an ordinary
   `call @print_int_v1(i64 %x)`. Undefined `print` becomes a normal
   "undefined variable" error.

## Why it's better

- One mechanism (extern) covers `print`, `panic`, `abort`, and any
  runtime primitive. No special cases in codegen.
- The runtime is a file the user can read and modify; it is not
  hidden in codegen.
- User shadowing of `print` works through normal scope rules, no
  `LLVMGetNamedFunction` needed.
- Paves the way for user-visible externs, needed for any real
  program that talks to the OS.

## Why deferred

- **Strings.** `extern ... = "print_int_v1"` needs a string literal.
  Or a hardcoded name-mangling scheme, but that is brittle.
- **Linking.** Current pipeline runs IR through `lli`. Linking a C
  runtime means switching the build step to `clang` (or `llc` +
  system linker).
- **`Nul` parameters** are not supported yet. An extern with a `Nul`
  argument requires deciding how `void` crosses the FFI boundary.

## Interim

Keep `isBuiltinPrint`. Add a second builtin only if genuinely
needed (`panic` for overflow checks is the leading candidate).
When the second one lands, extract a single `BuiltinSpec` table
(name, type, codegen emitter) in `src/backend/builtins.nim`, so
`installBuiltins` and `isBuiltinX` share one source of truth. Do
not grow the list past 2–3 before the extern mechanism exists.
