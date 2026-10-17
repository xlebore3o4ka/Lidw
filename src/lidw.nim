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
  echo "usage: lidw parse '<expr>'              print token stream"
  echo "       lidw ast '<expr>'                print AST"
  echo "       lidw check '<expr>'              run sema, print typed AST"
  echo "       lidw build '<expr>'              emit LLVM IR (skeleton)"
  echo "       lidw --version         print version"

proc needExpr(cmd: string, args: seq[string]) =
  if args.len < 2:
    stderr.writeLine "error: " & cmd & " requires an expression"
    quit(1)

proc main() =
  let args = commandLineParams()
  if args.len < 1:
    usage(); quit(1)
  let cmd = args[0]
  if cmd in ["--version", "-v", "version"]:
    echo LidwVersion
    quit(0)
  try:
    case cmd
    of "parse":
      needExpr(cmd, args)
      for t in lexAll(args[1]):
        echo $t, " @ ", t.line, ":", t.col
    of "ast":
      needExpr(cmd, args)
      echo $parseProgram(lexAll(args[1]))
    of "check":
      needExpr(cmd, args)
      echo $runSema(parseProgram(lexAll(args[1])))
    of "build":
      needExpr(cmd, args)
      echo emitModule(runSema(parseProgram(lexAll(args[1]))))
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

