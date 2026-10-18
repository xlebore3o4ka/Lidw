# Functions

## Declaration

```
Int(Int a) f = a + 1
```

A function declaration is a regular declaration whose type is a
function type `T(A, B)`. `Int(Int a) f = ...` reads as "f is a
function that takes Int and returns Int".

The body is a single expression. It is checked against the return
type. A multi-statement body is a block `( ... )` whose value comes
from `is`. Assignment is an expression
(see [expressions.md](expressions.md#assignment)), so the body can
be an assignment:

```
Int(Int a$) f = a = 1     -- body assigns a = 1, returns 1
```

```
Int(Int a) f = a + 1
Int(Int a) g = (Int y = a + 1; is y * 2)
Int(Int a) abs2 = if a < 0 (is -a) else a
```

Function declarations are only allowed at program top level. Inside
a block `( ... )` a function declaration is a sema error.

## Parameters

- `Int a` — immutable parameter. Assigned to inside the body: sema
  error.
- `Int a$` — mutable parameter. Caller's variable can be modified.

Every parameter of a function declaration must have a name. The
parser accepts unnamed types in type position (so `Int(Int)` is a
valid type expression), but the declaration site rejects them:

```
Int(Int a) f = a + 1   -- ok
Int(Int) f = 1         -- sema error: parameter must be named
Int() f = 1            -- ok, function with zero parameters
```

For a function that takes no arguments, use `Int()`. A wildcard
parameter (`_`) for explicitly ignored arguments is planned.

## Calling

```
f(1, 2)
```

Call is postfix: `expr(args)`. Any expression that resolves to a
function type is callable. In practice sema rejects calls where the
callee is not an identifier bound to a function.

`f()` with no arguments is valid. Trailing comma is tolerated by the
parser. Argument count must match parameter count, and each argument
must fit its parameter type.

## Mutable parameters

`Int a$` binds `a` by reference. Inside the body `a = expr` modifies
the caller's variable. The result of `f(x)` for `Int x` is that `x`
may have changed after the call.

Caller rules (sema):

- Pass a mutable identifier: `f(x)` where `x` is a mutable variable.
- Literals, arithmetic, comparisons, casts, `if`-expressions, and
  blocks are all **immutable** values. Passing them to a mutable
  parameter is an error.
- Passing an immutable variable (`Int x! = ...`) is an error.
- Passing a mutable parameter of the enclosing function is an error
  (parameters are immutable by default; only `$` makes one mutable).

Codegen passes mutable parameters as LLVM `ptr` to the caller's
`alloca`. Mutable writes go through the pointer and persist after
the call.

## Recursion and forward references

Top-level sema is two-pass: pass 1 registers every function
declaration in the program scope, pass 2 checks bodies. This means:

- Recursion works: `Int(Int n) fact = if n <= 1 1 else n * fact(n - 1)`.
- Forward references work: a function can call another declared
  later in the file.
- Inside a block, declarations are still linear. A function body
  cannot reference a local declared after it.

## Builtins

### `print(Int)`

Writes the value to stdout, followed by a newline. Returns `Nul`, so
it only works in statement position.

```
print(5)             -- ok, statement
Int x = print(5)     -- sema error: Nul does not fit i64
```

`print` lives in the root scope. A user declaration of `print` in the
program scope shadows it. Codegen distinguishes: if a `@print` LLVM
function exists in the module (user-declared), it is called normally;
otherwise the call is lowered to `printf("%ld\n", x)`.

`print` of anything other than `Int` is not supported yet. For
`Bool`, use `print(b as Int)` (0 or 1). For narrow ints, use
`print(x as Int)`. Strings do not exist.

### `panic()`

Aborts the program via `llvm.trap`. No return value (`Nul()`). Use
in statement position, typically as a guard:

```
Int(Int a) f = (if a < 0 panic(); is a)
```

`panic` is a builtin symbol in the root scope. User declarations
shadow it (codegen calls the user's `panic` instead of the trap).
See [overflow.md](overflow.md) for checked arithmetic and when
`panic` fires automatically.


## Not yet supported

- `return` for early exit.
- `Nul`-returning functions (no side effects exist yet).
- Function values: `Int(Int) g = f` (typechecks, but assigning a
  function to a variable is not implemented).
- Overloading, default arguments, variadic parameters, generics,
  nested functions.
