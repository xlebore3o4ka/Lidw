# LIDW language reference

**LIDW** — *the Language that I Didn't Write*. A homoiconic, compiled
language. Design in progress; this reference tracks what the current
build actually understands.

## Status

| Aspect             | Parser | Sema  | Codegen |
|--------------------|:------:|:-----:|:-------:|
| Arithmetic         |   ok   |  ok   |  partial|
| Comparisons        |   ok   |  ok   |  partial|
| Declarations       |   ok   |  ok   |  partial|
| Assignment         |   ok   |  ok   |  partial|
| Mutability         |   ok   |  ok   |  partial|
| Blocks & scope     |   ok   |  ok   |  partial|
| `if`/`elif`/`else` |   ok   |  ok   |  partial|
| `while`            |   ok   |  ok   |  partial|
| `break`            |   ok   |  ok   |  partial|
| `continue`         |   ok   |  ok   |  partial|

| `is`               |   ok   |  ok   |  partial|

| Narrow int types   |   ok   |  ok   |  partial|
| Cast (`as`)        |   ok   |  ok   |  partial|
| Functions          |   ok   |  ok   |  partial|
| Comments           |   ok   |  ok   |   ok    |
| Strings            |   —    |  —    |   —     |
| Floats             |   ok   |  —    |   —     |

Parser *ok*: `lidw ast '<src>'` builds a tree.
Sema *ok*: `lidw check '<src>'` assigns types and accepts or rejects
with `lekSema`.
Codegen *partial*: `lidw build '<src>'` emits LLVM IR that compiles
and runs, but some semantics are temporary or missing (see
[codegen.md](codegen.md)).

Comments are lexer-only: the lexer strips them as trivia, so the
parser, sema, and codegen never see them. All three columns are
marked *ok* because there is nothing for them to do.

## Documents

- [syntax.md](syntax.md) — lexical structure
- [types.md](types.md) — type system
- [declarations.md](declarations.md) — variables, mutability
- [expressions.md](expressions.md) — operators, if, is
- [blocks.md](blocks.md) — grouping, blocks, scope
- [codegen.md](codegen.md) — LLVM IR emission
- [errors.md](errors.md) — error kinds and messages
- [planned.md](planned.md) — not started

## Tools

```
lidw parse <expr|file>   # token stream with positions
lidw ast   <expr|file>   # AST (no types)
lidw check <expr|file>   # typed AST (sema)
lidw build <expr|file>   # LLVM IR text (sema + codegen)
lidw --version           # version from VERSION file
```

`<expr>` is LIDW source quoted in the shell. `<file>` is a path to
an existing file: its contents are read as LIDW source. Detection:
if the argument names an existing regular file, contents are used;
otherwise the argument itself is the source. No extension check.
