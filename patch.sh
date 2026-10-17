set -e
set -o pipefail

echo "=== git status (before) ==="
git status --short

# 1. parseParam: fix if not already fixed
python3 - <<'PYEOF'
p = "src/parser/parser.nim"
s = open(p).read()
if "var endLine = ty.line" in s:
    print("parseParam: already fixed")
else:
    old = '''proc parseParam(p: var Parser): Node =
  let ty = parseType(p)
  var name = ""
  var mut = muImmutable
  var endTok = ty
  if p.peek().kind == tkIdent:
    let nameTok = p.peek()
    p.advance()
    name = nameTok.word
    if p.peek().kind == tkBang:
      endTok = p.peek()
      mut = muImmutable
      p.advance()
    elif p.peek().kind == tkDollar:
      endTok = p.peek()
      mut = muMutable
      p.advance()
    else:
      endTok = nameTok
  Node(kind: nkParam, paramType: ty, paramName: name, paramMut: mut,
       line: endTok.line, col: endTok.col)
'''
    new = '''proc parseParam(p: var Parser): Node =
  let ty = parseType(p)
  var name = ""
  var mut = muImmutable
  var endLine = ty.line
  var endCol = ty.col
  if p.peek().kind == tkIdent:
    let nameTok = p.peek()
    p.advance()
    name = nameTok.word
    endLine = nameTok.line
    endCol = nameTok.col
    if p.peek().kind == tkBang:
      let mTok = p.peek()
      endLine = mTok.line
      endCol = mTok.col
      p.advance()
    elif p.peek().kind == tkDollar:
      let mTok = p.peek()
      mut = muMutable
      endLine = mTok.line
      endCol = mTok.col
      p.advance()
  Node(kind: nkParam, paramType: ty, paramName: name, paramMut: mut,
       line: endLine, col: endCol)
'''
    assert old in s, "parser-param-fix"
    s = s.replace(old, new, 1)
    open(p, "w").write(s)
    print("parseParam: fixed")
PYEOF

# 2. base.nim: add visitFnType/visitParam dispatch + Noop if missing
python3 - <<'PYEOF'
p = "src/visitors/base.nim"
s = open(p).read()
if "visitFnType" in s:
    print("base.nim: already ok")
else:
    old = '  of nkTypeName: v.visitTypeName(n)\n'
    assert old in s, "base-dispatch"
    s = s.replace(old, old + '  of nkFnType: v.visitFnType(n)\n  of nkParam:  v.visitParam(n)\n', 1)
    old2 = '  proc visitTypeName*(v: var Noop, n: Node) = discard\n'
    assert old2 in s, "base-noop"
    s = s.replace(old2, old2 + '  proc visitFnType*(v: var Noop, n: Node) = discard\n  proc visitParam*(v: var Noop, n: Node) = discard\n', 1)
    open(p, "w").write(s)
    print("base.nim: updated")
PYEOF

# 3. sema.nim: add forward + stubs if missing
python3 - <<'PYEOF'
p = "src/visitors/sema.nim"
s = open(p).read()
if "visitFnType" in s:
    print("sema.nim: already ok")
else:
    old = 'proc visitTypeName*(v: var SemaVisitor, n: Node)\n'
    assert old in s, "sema-forward"
    s = s.replace(old, old + 'proc visitFnType*(v: var SemaVisitor, n: Node)\nproc visitParam*(v: var SemaVisitor, n: Node)\n', 1)
    old2 = 'proc runSema*(n: Node): Node =\n'
    assert old2 in s, "sema-stub"
    stub = '''proc visitFnType*(v: var SemaVisitor, n: Node) =
  raise lidwError(lekSema, "function types not implemented yet (Fa.3)",
                  n.line, n.col)

proc visitParam*(v: var SemaVisitor, n: Node) =
  raise lidwError(lekSema, "parameters not implemented yet (Fa.3)",
                  n.line, n.col)

'''
    s = s.replace(old2, stub + old2, 1)
    open(p, "w").write(s)
    print("sema.nim: updated")
PYEOF

# 4. Compile
nim check --hints:off src/visitors/base.nim
nim check --hints:off src/visitors/sema.nim
nim check --hints:off src/lidw.nim
nim c --hints:off --warnings:off -o:bin/lidw src/lidw.nim

# 5. Smoke
echo "=== smoke ==="
./bin/lidw parse 'a, b'
./bin/lidw ast 'Int(Int a) f = a + 1'

# 6. Commit current dirty state
git add -A
git commit -m "add: parse function types T(A, B) (Fa.2)" || echo "commit: nothing new"

# 7. Tests
nimble test 2>&1 | grep -v '\[OK\]'