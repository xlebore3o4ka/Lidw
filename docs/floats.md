# Floats

Two IEEE 754 float types: `F32` (single) and `F64` (double).
`Float` is an alias for `F64`.

## Literals

```
1.5           -- fLit(1.5)
-2.75         -- fLit(-2.75)
inf           -- fLit(Inf)
-inf          -- fLit(-Inf), via unary minus fold
nan           -- fLit(NaN)
```

Float literals have type `fLit(v)` until a concrete context assigns
them `F32` or `F64`. Integer literals (`iLit`) adapt to a float
context if the value is representable:

```
F64 x = 5      -- iLit(5) -> F64
F32 x = 5      -- ok, 5 fits F32
Int x = 1.5    -- sema error: fLit does not fit Int
```

`inf` and `nan` are builtin values (like `true`/`false`), not
keywords. A user declaration of `inf` shadows them.

## Operators

`+ - * /` on floats. `%` is **not** defined for Float (sema error).
Arithmetic does not panic: overflow becomes `Inf`, `0.0 / 0.0` is
`NaN`. IEEE 754 semantics; no overflow checks.

Precedence is the same as for Int.

## Mixing with Int

| Expression      | Result  | Rule                                    |
|-----------------|---------|-----------------------------------------|
| `fLit + fLit`   | `fLit`  | folded                                  |
| `fLit + iLit`   | `fLit`  | folded (Int converted to float)         |
| `fLit + F64`    | `F64`   | literal adapts                          |
| `fLit + F32`    | `F32`   | literal adapts if representable         |
| `F64 + F64`     | `F64`   |                                         |
| `F32 + F32`     | `F32`   |                                         |
| `F32 + F64`     | `F64`   | widen to F64                            |
| `iLit + F64`    | `F64`   | literal adapts                          |
| `Int + F64`     | error   | explicit `as F64` required              |
| `Float + Bool`  | error   |                                         |

**Rule:** Int and Float never mix implicitly. Convert explicitly:

```
Int x = 5
F64 y = x as F64    -- sitofp
F64 z = 5 as F64    -- iLit as F64 = const real
```

## Comparisons

`== != < <= > >=` on floats produce `Bool`. Same shape as Int:
Float/Float, Float/iLit, Float/fLit; Int + Float is an error.
Ordered comparison semantics: `NaN == x` is false, `NaN != x` is
true, all other `NaN` comparisons false.

## Casts

`as` is the only way to mix Int and Float in a value.

| Source       | Target       | IR              |
|--------------|--------------|-----------------|
| `Int`        | `F64` / `F32`| `sitofp` / `uitofp` (signed / unsigned src) |
| `F64`/`F32`  | `Int`        | `fptosi` / `fptoui` |
| `F32`        | `F64`        | `fpext`         |
| `F64`        | `F32`        | `fptrunc`       |
| `iLit`       | `F64`/`F32`  | `LLVMConstReal` (folded) |
| `fLit`       | `Int`        | `LLVMConstInt(trunc)` (folded) |
| `fLit`       | `Bool`       | `fv != 0` (folded; NaN -> true) |
| `Float`      | `Bool`       | `fcmp une x, 0.0` (NaN -> true) |
| `Bool`       | `Float`      | **error** (use `as Int` first) |

`Float -> Bool` is `x != 0`; NaN is treated as non-zero (true).

## Debug info

`F32` and `F64` emit `DW_TAG_base_type` with `DW_ATE_float`.
`gdb` shows float locals as `double`.

## Not yet

- `print(F64)`: `print` is Int-only. Use `x as Int` for debug
  output (loses the fractional part).
- `1e10` exponent syntax; only `digits.digits` is lexed.
- `%` (fmod) on floats.
- Float literals as function parameters of `F32`: needs careful
  round-trip (`fLit` is `double`; `fLit` fits `F32` only if finite
  and within range).

## See also

- [types.md](types.md) — full type system
- [expressions.md](expressions.md) — arithmetic, comparisons
