# Declarations and mutability

## Forms

```
Int x           # mutable, no initializer (default value)
Int x = 10      # mutable, with initializer
Int x$          # mutable, explicit `$` (same as `Int x`)
Int x$ = 10     # mutable, with initializer
Int x!          # immutable, no initializer
Int x! = 10     # immutable, with initializer
```

`!` marks a declaration immutable. `$` marks it mutable explicitly;
it is redundant with the default but reserves syntax for function
parameters (planned, see [planned.md](planned.md)).

Postfix markers are only valid in declarations. `x!` in an expression
is a parse error.

## Defaults

No initializer still binds the name with the declared type:

```
Int x          # x : Int, value 0 at runtime
Bool b         # b : Bool, value false at runtime
```

Sema tracks the type. Runtime values are a codegen concern; today
`lidw` does not execute anything.

## Redefinition

A name may be declared only once per scope:

```
Int x = 1
Int x = 2       # sema error: redeclaration of x (previously declared at 1:1)
```

The error carries both positions.

## Shadowing

A name may be redeclared in a nested scope:

```
Int x = 1
(Int x = 2 x)   # inner x shadows outer x
x + 1           # outer x is visible again after the block closes
```

Parentheses with a single statement are grouping, not a block, so no
new scope is opened:

```
Int x = 1
(Int x = 2)     # sema error: redeclaration of x
```

To force a block (and a new scope), put two statements inside:

```
(Int x = 2 x)   # block, inner scope, no error
```

## Assignment

```
x = expr
```

Assignment requires `x` to be a mutable variable already in scope.

- Undefined `x` → sema error `undefined variable: x`.
- Immutable `x` → sema error `cannot assign to immutable variable x`.
- Mutable `x` → the right-hand side is analyzed in context of `x`'s
  type. If it does not fit → `cannot assign <got> to <type> variable x`.

## Initialization order

Declarations are processed in order. Using a name before its
declaration is an error:

```
Int y = x       # sema error: undefined variable: x
Int x = 1
```
