# Codegen

`lidw build '<src>'` lowers the program to LLVM IR text on stdout.
The pipeline is: lex -> parse -> sema -> codegen. Sema must run
first; the codegen relies on `Node.typ` being set.

## Toolchain

Links against `libLLVM-23`. IR is printed as text, not written to a
file or executed. To run the result:

```
lidw build '1 + 2' | lli
```

`lli` executes the IR directly. Because `main` returns the value
described below, the shell `$?` gives you that number (mod 256).

## Temporary semantics

**`main` returns the last value expression.** This is a scaffold
until `print` and other side effects exist.

- The program root is `nkProgram`. Its statements execute in order.
- Each value expression (literal, ident, binop, value-`if`, value-
  `is`, value-block) replaces the current return value.
- Statements (decl, assign, statement-`if`, statement-block) update
  this return value only if they end in a value expression.
- If no value expression is ever evaluated, `main` returns 0.

Example:

```
lidw build 'Int x = 10 x + 1'
```

produces IR whose `ret` is `%add = add i64 %x_load, 1`.

**Bool return.** If the last value expression has type `Bool`, the
codegen zero-extends it to `i64` before `ret`. So `1 < 2` returns 1
(true), `1 > 2` returns 0.

**TODO#39**: when `print` arrives, this scaffold will be replaced by
real program semantics (main returns 0 unconditionally, side effects
go to stdout).

## Supported

### Literals and arithmetic

`nkInt` -> `i64` constant. `+ - * / %` -> `add sub mul sdiv srem`.
Unary `-` -> `sub 0, x`. LLVM constant-folds any operation whose
operands are all constants: `1 + 2` becomes `ret i64 3` with no
`add` instruction.

### Variables

Every `Int x` declaration creates an `alloca i64` in the current
block. Initialization is a `store`. Every `x` read is `load`.
Every `x = expr` is a `store` to the same slot. `Bool x` uses
`alloca i1` and coerces `iLit` to `i1` via `icmp ne i64 v, 0`.

**Scope.** The codegen keeps a stack of name tables, mirroring the
sema scopes. A block opens a new table; shadowing creates a new
alloca; the outer alloca becomes visible again after the block
closes. LLVM auto-renames duplicate alloca names in the printed IR
(`%x`, `%x1`, `%x2`).

**TODO#41**: alloca currently goes into the current basic block,
not the function entry. This is fine for linear control flow. Once
loops exist, alloca in a loop body will be re-executed each
iteration and produce wrong results. Fix before adding loops.

### Comparisons

`== != < <= > >=` on Int -> `icmp eq/ne/slt/sle/sgt/sge i64`,
result `i1`. On Bool -> `icmp eq/ne i1`. Mixed Int and Bool is
rejected by sema, never reaches codegen. Literal comparisons
constant-fold.

### `if`

**Statement `if`** (typ is `nul`): cond -> `i1`, then `br i1` into
`then`/`else`/`merge` basic blocks. Branches are emitted as
statements; result discarded. `else` missing -> `else` = `merge`,
no instructions in the else path.

**Value `if`** (typ is `Int` or `Bool`): both branches are value
expressions. Each evaluates to an `i64` (or `i1` for Bool); a
`phi` node in `merge` picks the value. If `else` is missing, the
false path uses `0` (or `false`).

### `is` and value-blocks

A block with type `Int` or `Bool` is a value-block. It opens a
scope, emits all statements, and yields the value of `is`:

```
Int x = (Int y = 10; is y); x    -- x = y
```

`is` is consumed by the block, not by the surrounding expression.
Branches of a value-`if` can be value-blocks:

```
Int x = if c (is 5) else (is 7); x
```

### Narrow int types

`I8 / U8 / I16 / U16 / I32 / U32 / U64` are supported end-to-end.

- Declarations: `alloca iN`, `store iN V`. An `iLit` initializer is
  emitted directly at width; the value already fits per sema.
- Binary arithmetic: both operands are coerced to a common kind
  (same rules as sema), then a single-width instruction is emitted.
  Division and modulo use `sdiv/udiv` and `srem/urem` based on the
  target kind. Overflow wraps silently at runtime.
- Comparisons: same common-kind coercion. Predicates are
  `icmp slt/sle/sgt/sge` for signed kinds and `icmp ult/ule/ugt/uge`
  for unsigned.
- Cast is the only way to move a value between concrete int kinds
  without an arithmetic operator; see below.
- `main` returns `i64`. Narrow results are extended by source
  signedness: `sext` for `I8/I16/I32`, `zext` for `U8/U16/U32/U64`.

### Cast (`as`)

Lowered by (source kind, target kind):

- `iLit -> Int`: `LLVMConstInt` at target width (wrap).
- `iLit -> Bool`: `LLVMConstInt(i1, v != 0, 0)`.
- `Int -> Int`: `trunc` / `sext` / `zext` by source signedness.
- `Int -> Bool`: `icmp ne iN %v, 0`.
- `Bool -> Int`: `zext i1 to iN`.
- `Bool -> Bool`: passthrough.

### `while` and `break`

`while` lowers to `while.cond` / `while.body` / `while.exit` blocks.
If the body contains `break` (detected structurally), an extra
`while.break` block collects all `break` sites. Exit emits
`phi i1`: `false` from `while.cond`, `true` from `while.break`.
Without `break`, no `while.break` block; exit value is constant
`false`.

`break` lowers to `br while.break`.

`ret` inside `while` exits the enclosing function and terminates the
current block; the loop's exit block is still emitted but may be
unreachable if every body path ends in `ret`.

### Functions


Declarations: `define iN @f(iN %0, ...)`. Each function is
registered as a declaration first (pass 1), then bodies are emitted
(pass 2), then `main` body (pass 3). LLVM prints definitions in any
order.

Parameters: immutable parameters are passed by value and copied into
an `alloca` inside the function. Mutable parameters (`$`) are passed
as LLVM `ptr` to the caller's `alloca`; writes go through the
pointer.

Calls: `call iN @f(iN %arg, ptr %slot, ...)`. Argument coercion
follows the same rules as arithmetic: literals at target width,
concrete ints via trunc/sext/zext.

Recursion and forward refs work because sema registers all top-level
functions before checking any body.

`main` return: same as before, the last value expression. Function
declarations at top level are skipped from the main body.

## Not supported (yet)

- **Integer overflow.** `add/sub/mul` use LLVM wrap semantics
  silently. Sema rejects literal overflow at compile time; runtime
  overflow will not panic.
- **Division by zero.** Sema rejects literal `1/0`; runtime
  `x/0` will hit LLVM UB.
- **Multiple `main`s.** Only one module, one `main` per build.
- **`print`, strings, floats.**
