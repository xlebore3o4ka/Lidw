import std/os
import ./version
import ./errors
import ./parser/tokens
import ./parser/lexer
import ./parser/ast
import ./parser/parser
import ./types
import ./visitors/sema

proc usage() =
  echo "lidw " & LidwVersion
  echo "usage: lidw parse '<expr>'              print token stream"
  echo "       lidw ast '<expr>'                print AST"
  echo "       lidw check [--ctx i64] '<expr>'  run sema, print typed AST"
  echo "       lidw --version         print version"

proc main() =
  let args = commandLineParams()
  if args.len < 1:
    usage(); quit(1)
  let cmd = args[0]
  if cmd in ["--version", "-v", "version"]:
    echo LidwVersion
    quit(0)
  if args.len < 2:
    usage(); quit(1)
  try:
    case cmd
    of "parse":
      for t in lexAll(args[1]):
        echo $t, " @ ", t.line, ":", t.col
    of "ast":
      echo $parseProgram(lexAll(args[1]))
    of "check":
      var ctx: LidwType = nil
      var expr = ""
      var i = 1
      while i < args.len:
        if args[i] == "--ctx":
          if i+1 >= args.len:
            stderr.writeLine "error: --ctx requires a type name"; quit(1)
          case args[i+1]
          of "i64": ctx = i64Type()
          else:
            stderr.writeLine "error: unknown type: " & args[i+1]; quit(1)
          i += 2
        else:
          expr = args[i]; i += 1
      if expr == "":
        stderr.writeLine "error: check requires an expression"; quit(1)
      echo $runSema(parseProgram(lexAll(expr)), ctx)
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

