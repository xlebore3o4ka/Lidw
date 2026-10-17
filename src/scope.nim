# Symbol table with scope tree and fast last-scope lookup.
# <NOTE>#17: table[name] holds the stack of scopes declaring name;
# lookup takes .last (innermost). open/close must be symmetric.

import std/tables
import ./types
import ./errors
import ./parser/ast

type
  Symbol* = object
    typ*: LidwType
    mut*: Mutability
    line*: int
    col*: int

  Scope* = ref object
    symbols*: Table[string, Symbol]
    parent*: Scope

  Symbols* = object
    table*: Table[string, seq[Scope]]
    current*: Scope

proc newSymbols*(): Symbols =
  result.table = initTable[string, seq[Scope]]()
  result.current = Scope(symbols: initTable[string, Symbol](), parent: nil)

proc open*(s: var Symbols): Scope =
  ## Push a new scope as child of current.
  let child = Scope(symbols: initTable[string, Symbol](), parent: s.current)
  s.current = child
  child

proc close*(s: var Symbols) =
  ## Pop current scope; remove its names from the lookup table.
  let leaving = s.current
  if leaving == nil or leaving.parent == nil:
    raise newException(AssertionDefect, "close: no scope to close")
  for name in leaving.symbols.keys:
    if s.table.hasKey(name):
      discard s.table[name].pop()
      if s.table[name].len == 0:
        s.table.del(name)
  s.current = leaving.parent

proc define*(s: var Symbols, name: string, typ: LidwType, mut: Mutability,
             line, col: int) =
  ## Bind name in current scope. Redefinition in the same scope raises.
  # <NOTE>#23: mutate seq via 's.table[name]' (var B overload); an
  # intermediate 'var stack = mgetOrPut(...)' can bind as a copy.
  if s.current.symbols.hasKey(name):
    let prev = s.current.symbols[name]
    raise lidwError(lekSema,
      "redeclaration of " & name & " (previously declared at " &
      $prev.line & ":" & $prev.col & ")", line, col)
  s.current.symbols[name] = Symbol(typ: typ, mut: mut, line: line, col: col)
  if s.table.hasKey(name):
    s.table[name].add(s.current)
  else:
    s.table[name] = @[s.current]

proc lookup*(s: Symbols, name: string): Symbol =
  ## Innermost active symbol for name; Symbol.typ == nil if not found.
  let stack = s.table.getOrDefault(name)
  if stack.len == 0: Symbol(typ: nil)
  else: stack[^1].symbols.getOrDefault(name)
