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
| `is`               |   ok   |  ok   |  partial|
| Functions          |   —    |  —    |   —     |
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
lidw parse '<src>'   # token stream with positions
lidw ast   '<src>'   # AST (no types)
lidw check '<src>'   # typed AST (sema)
lidw build '<src>'   # LLVM IR text (sema + codegen)
lidw --version       # version from VERSION file
```
