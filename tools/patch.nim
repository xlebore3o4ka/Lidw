# Nim-based patch tool: replaces "python3 - <<'PYEOF' ... PYEOF".
#
# Protocol on stdin (multiple patches allowed):
#
#   ### FILE: path/to/file.nim
#   ### MARKER: short-name
#   ### OLD
#   ...old text verbatim...
#   ### NEW
#   ...new text verbatim...
#
#   ### FILE: path/to/another.nim
#   ### MARKER: ...
#   ...
#
# Each block of OLD/NEW is joined with "\n" and gets a trailing "\n"
# appended (matches the "'''...'''" behavior we had with Python).
# A patch is idempotent: if NEW already appears in the file, it's
# skipped. If OLD is missing and NEW is missing, that's a hard error.

import std/strutils


type
  Patch = object
    file: string
    marker: string
    old: string
    new: string

proc parse(input: string): seq[Patch] =
  var
    patches: seq[Patch]
    cur = Patch()
    state = ""
    buf: seq[string]

  proc flush() =
    case state
    of "old": cur.old = buf.join("\n") & (if buf.len > 0: "\n" else: "")
    of "new": cur.new = buf.join("\n") & (if buf.len > 0: "\n" else: "")
    else: discard
    buf.setLen(0)

  proc commit() =
    if cur.file.len > 0:
      if cur.old.len == 0 and cur.new.len == 0:
        stderr.writeLine "patch: " & cur.file & " has no OLD/NEW"
        quit(1)
      patches.add cur
    cur = Patch()

  for l in input.splitLines():
    if l.startsWith("### FILE: "):
      flush(); commit()
      cur.file = l[10..^1].strip
    elif l.startsWith("### MARKER: "):
      flush()
      cur.marker = l[12..^1].strip
    elif l == "### OLD":
      flush()
      state = "old"
    elif l == "### NEW":
      flush()
      state = "new"
    else:
      if state in ["old", "new"]:
        buf.add l
  flush(); commit()
  result = patches

proc apply(p: Patch) =
  # <NOTE>#130: OLD wins over the "already applied" check. Only if OLD
  # is not in the file, and NEW (stripped) is present, do we assume a
  # previous run already applied this patch. Otherwise it's a hard
  # error. This fixes the case where NEW is empty (delete) — an empty
  # NEW is always "in" any string, so an OLD-first order is required.
  let s = readFile(p.file)
  let idx = s.find(p.old)
  if idx >= 0:
    writeFile(p.file, s[0 ..< idx] & p.new & s[idx + p.old.len .. ^1])
    echo "patched: ", p.file, " (", p.marker, ")"
    return
  if p.new.strip.len > 0 and p.new in s:
    echo "skip: ", p.file, " (", p.marker, ") already applied"
    return
  stderr.writeLine "patch: block not found in " & p.file &
                   " (marker " & p.marker & ")"
  stderr.writeLine "--- looked for ---"
  stderr.writeLine p.old
  stderr.writeLine "--- end ---"
  quit(1)


proc main() =
  let input = stdin.readAll()
  let patches = parse(input)
  if patches.len == 0:
    stderr.writeLine "patch: no patches in input"
    quit(1)
  for p in patches:
    apply(p)
  echo "ok: ", patches.len, " patch(es)"

when isMainModule:
  main()
