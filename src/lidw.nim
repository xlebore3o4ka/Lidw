import std/os
import ./version
import ./errors
import ./parser/tokens
import ./parser/lexer
import ./parser/ast
import ./parser/parser
import ./visitors/sema
import ./backend/codegen

proc usage() =
  echo "lidw " & LidwVersion
  echo "usage: lidw parse <expr|file>   print token stream"
  echo "       lidw ast   <expr|file>   print AST"
  echo "       lidw check <expr|file>   run sema, print typed AST"
  echo "       lidw build <expr|file>   emit LLVM IR"
  echo "       lidw --version           print version"
  echo ""
  echo "<expr> is LIDW source quoted in the shell; <file> is a path"
  echo "to an existing file. If the argument names a file, its"
  echo "contents are read as LIDW source."

proc needArg(cmd: string, args: seq[string]) =
  if args.len < 2:
    stderr.writeLine "error: " & cmd & " requires a source (expression or file)"
    quit(1)

proc loadSource(arg: string): string =
  ## <NOTE>#101: if `arg` names an existing regular file, read its
  ## contents as LIDW source. Otherwise `arg` is the source text. No
  ## extension check; `os.fileExists` uses S_ISREG so directories and
  ## devices are treated as source (which will lex-fail loudly).
  if fileExists(arg): readFile(arg) else: arg

proc main() =
  let args = commandLineParams()
  if args.len < 1:
    usage(); quit(1)
  let cmd = args[0]
  if cmd in ["--version", "-v", "version"]:
    echo LidwVersion
    quit(0)
  var source = ""
  if args.len >= 2:
    try:
      source = loadSource(args[1])
    except IOError as e:
      stderr.writeLine "error: cannot read " & args[1] & ": " & e.msg
      quit(2)
  try:
    case cmd
    of "parse":
      needArg(cmd, args)
      for t in lexAll(source):
        echo $t, " @ ", t.line, ":", t.col
    of "ast":
      needArg(cmd, args)
      echo $parseProgram(lexAll(source))
    of "check":
      needArg(cmd, args)
      echo $runSema(parseProgram(lexAll(source)))
    of "build":
      needArg(cmd, args)
      echo emitModule(runSema(parseProgram(lexAll(source))))
    else:
      usage(); quit(1)
  except LidwError as e:
    stderr.writeLine e.kind.kindName & " error: " & e.msg &
      " at " & $e.line & ":" & $e.col
    quit(1)
  except CatchableError as e:
    stderr.writeLine "internal error: " & e.msg
    quit(2)

main()

