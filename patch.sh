set -e

# Fix 1: ensure lekSema exists in errors.nim
python3 - <<'PYEOF'
p = "src/errors.nim"
s = open(p).read()
if "lekSema" in s:
    print("errors.nim already has lekSema — skip")
else:
    old_enum = "    lekLex, lekParse, lekRuntime\n"
    new_enum = "    lekLex, lekParse, lekSema, lekRuntime\n"
    assert old_enum in s, "errors-enum"
    s = s.replace(old_enum, new_enum, 1)

    old_case = '''  of lekLex:     "lex"
  of lekParse:   "parse"
  of lekRuntime: "runtime"
'''
    new_case = '''  of lekLex:     "lex"
  of lekParse:   "parse"
  of lekSema:    "sema"
  of lekRuntime: "runtime"
'''
    assert old_case in s, "errors-case"
    s = s.replace(old_case, new_case, 1)
    open(p, "w").write(s)
PYEOF

# Fix 2: forward-declare all four handlers so visit instantiation resolves
python3 - <<'PYEOF'
p = "src/visitors/sema.nim"
s = open(p).read()

if "# Forward declarations:" in s:
    print("sema.nim already has forward decls — skip")
else:
    old = '''proc newSemaVisitor*(ctx: LidwType = nil): SemaVisitor =
  SemaVisitor(ctx: ctx)
'''
    new = '''proc newSemaVisitor*(ctx: LidwType = nil): SemaVisitor =
  SemaVisitor(ctx: ctx)

# Forward declarations: base.visit dispatches to all four handlers;
# without these, compiling visitUnary's body triggers visit instantiation
# while visitBinOp isn't declared yet.
proc visitInt*(v: var SemaVisitor, n: Node)
proc visitFloat*(v: var SemaVisitor, n: Node)
proc visitUnary*(v: var SemaVisitor, n: Node)
proc visitBinOp*(v: var SemaVisitor, n: Node)
'''
    assert old in s, "sema-forward"
    s = s.replace(old, new, 1)
    open(p, "w").write(s)
PYEOF

nim check --hints:off src/errors.nim && \
nim check --hints:off src/visitors/sema.nim && \
nim check --hints:off src/lidw.nim && \
nim c --hints:off -o:bin/lidw src/lidw.nim && \
echo '--- no ctx' && \
./bin/lidw check '10 + 4' && \
echo '--- ctx i64' && \
./bin/lidw check --ctx i64 '10 + 4' && \
echo '--- overflow' && \
(./bin/lidw check '9223372036854775807 + 1' || echo "exit=$?") && \
git add -A && \
git commit -m "fix: forward-declare sema handlers and add lekSema"