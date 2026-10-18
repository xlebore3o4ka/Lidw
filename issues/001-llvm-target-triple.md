# 001 — LLVM target triple and data layout are unset

**Status:** resolved — `initTarget` in codegen sets target triple
from `LLVMGetDefaultTargetTriple` and sets data layout from a
hardcoded x86_64 string (matching `clang -print-target-triple` on
this machine). `store i64` now emits `align 8` (was `align 4`),
clang has no `-Woverride-module` warning. Portable detection needs
`LLVMGetTargetFromTriple` + `LLVMCreateTargetMachine` +
`LLVMCreateTargetDataLayout`, deferred.

**Layer:** codegen
**Related:** overflow checks, div-by-zero checks

## Problem

`emitModule` creates the module with `LLVMModuleCreateWithNameInContext`
but never calls `LLVMSetTarget` or `LLVMSetDataLayout`. Without
either, LLVM falls back to a generic data layout where `i64` has
abi-alignment 4 (not 8, as on x86-64).

Evidence: `store i64 ...` on an `alloca i64` is emitted as
`store i64 ..., ptr %n, align 4` — correct for a generic target,
wrong for x86-64.

## Why it matters

Not a correctness bug today. On x86-64 unaligned stores are legal,
and the `alloca` itself carries `align 8`, so an optimizer can
recover the alignment. We run IR through `lli` with default
optimization, so nothing breaks.

The real cost is target-specific behavior:

- Data layout affects struct layout, vector alignment, `alloca`
  alignment, atomics, pointer-size assumptions.
- Once we emit `llvm.sadd.with.overflow` and panic paths (planned
  overflow checks), target-specific intrinsics and calling
  conventions matter.
- If we ever emit `memcpy`, `memset`, or atomic ops, they need the
  correct target.

## Fix

`emitModule` should call:

```
LLVMSetTarget(llmod, "x86_64-pc-linux-gnu")
LLVMSetDataLayout(llmod, <string from llvm-config>)
```

Bindings to add: `LLVMSetTarget`, `LLVMSetDataLayout`,
`LLVMGetDefaultTargetTriple`, `LLVMGetDataLayoutStr`. The simplest
path is to read `llvm-config --host-target` and
`llvm-config --data-layout` at build time and embed the strings.

Emitting `align 8` explicitly on the store would also fix the
specific warning, but doesn't address the general problem.

## Deferred because

Nothing in the current IR breaks; LLVM treats alignment on `store`
as a hint. Fix alongside overflow checks, where target-specific
behavior first matters.
