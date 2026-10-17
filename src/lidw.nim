import std/os
import ./version
import ./errors
import ./parser/tokens
import ./parser/lexer
import ./parser/ast
import ./parser/parser

proc usage() =
  echo "lidw " & LidwVersion
  echo "usage: lidw parse '<expr>'    print token stream"
  echo "       lidw ast '<expr>'      print AST"
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
      echo $parse(lexAll(args[1]))
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

