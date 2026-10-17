# LIDW language reference

**LIDW** — *the Language that I Didn't Write*. A homoiconic, compiled
language. Design in progress; this reference tracks what the current
build actually understands.

## Status

| Aspect             | Parser | Sema  | Codegen |
|--------------------|:------:|:-----:|:-------:|
| Arithmetic         |   ok   |  ok   |   —     |
| Comparisons        |   ok   |  ok   |   —     |
| Declarations       |   ok   |  ok   |   —     |
| Assignment         |   ok   |  ok   |   —     |
| Mutability         |   ok   |  ok   |   —     |
| Blocks & scope     |   ok   |  ok   |   —     |
| `if`/`elif`/`else` |   ok   |  ok   |   —     |
| `is`               |   ok   |  ok   |   —     |
| Functions          |   —    |  —    |   —     |
| Comments           |   —    |  —    |   —     |
| Strings            |   —    |  —    |   —     |
| Floats             |   ok   |  —    |   —     |

Parser *ok*: `lidw ast '<src>'` builds a tree.
Sema *ok*: `lidw check '<src>'` assigns types and accepts or rejects
with `lekSema`. `—`: not implemented at all.

## Documents

- [syntax.md](syntax.md) — lexical structure
- [types.md](types.md) — type system
- [declarations.md](declarations.md) — variables, mutability
- [expressions.md](expressions.md) — operators, if, is
- [blocks.md](blocks.md) — grouping, blocks, scope
- [errors.md](errors.md) — error kinds and messages
- [planned.md](planned.md) — not started

## Tools

```
lidw parse '<src>'   # token stream with positions
lidw ast   '<src>'   # AST (no types)
lidw check '<src>'   # typed AST (sema)
lidw --version       # version from VERSION file
```
