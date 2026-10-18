# Debugging

Every `lidw build` emits LLVM IR with full debug info (DWARF v5):

- `DICompileUnit` — one per module, `DW_LANG_C`, producer
  `lidw <version>`.
- `DIFile` — filename is the input path, or `<expr>` for shell
  strings.
- `DISubprogram` — one per function (`main` included), with line
  numbers from source.
- `DILocation` — on every instruction.
- `DILocalVariable` + `dbg.declare` — for every `Int x`, `Bool b`,
  etc., so `p x` works in `gdb`.

`lli` ignores debug info (JIT). To use `gdb` or `lldb`, compile
through `clang`:

```
lidw build test.lidw > test.ll
clang test.ll -o test -g -O0
gdb test
```

Then `gdb` understands source locations:

```
(gdb) break test.lidw:5
Breakpoint 1 at 0x115c: file test.lidw, line 5.
(gdb) run
(gdb) info locals
x = 5
y = 6
(gdb) print x
$1 = 5
```

## What is in the DWARF

- `DW_AT_producer: lidw <version>` on the compile unit.
- `DW_AT_language: DW_LANG_C` (DWARF has no LIDW tag; C is the
  closest match).
- `DW_TAG_subprogram` for each function, with `DW_AT_low_pc` and
  `DW_AT_high_pc`.
- `DW_TAG_variable` for each local, with `DW_AT_location` (frame
  base offset) and `DW_AT_type`.
- `DW_TAG_base_type` for `i8/u8/i16/u16/i32/u32/i64/u64/Bool`.

## Limitations

- `DW_AT_decl_file` is always index 0; multi-file programs (do not
  exist yet) would need per-file `DIFile`.
- The data layout is hardcoded to x86-64. Cross-compilation is not
  supported yet (see `issues/001-llvm-target-triple.md`).
- Variable types for `iLit` literals map to `i64` (the literal has
  no concrete width until it is assigned).
- `gdb` may show uninitialized values between the declaration and
  the `store` if you break exactly on the declaration line; break
  on the line *after*.

## Verifying the DWARF

```
readelf -S test | grep debug     # sections
readelf --debug-dump=info test   # DIEs
readelf --debug-dump=decodedline test  # line table
```
