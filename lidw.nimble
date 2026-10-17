import std/strutils

# Package

version       = readFile("VERSION").strip()
author        = "xlebore3o4ka & DeepSeek"
description   = "LIDW - the Language that I Didn't Write"
license       = "AGPL-3.0"
srcDir        = "src"
binDir        = "bin"
bin           = @["lidw"]


# Dependencies

requires "nim >= 2.2.10"

task test, "Run all tests":
  exec "nim c -r --hints:off -o:/tmp/lidw_tests_lexer tests/lexer_test.nim"
  exec "nim c -r --hints:off -o:/tmp/lidw_tests_parser tests/parser_test.nim"
  exec "nim c -r --hints:off -o:/tmp/lidw_tests_sema tests/sema_test.nim"
  exec "nim c -r --hints:off -o:/tmp/lidw_tests_backend_llvm tests/backend_llvm_test.nim"
  exec "nim c -r --hints:off -o:/tmp/lidw_tests_types tests/types_test.nim"

task myRun, "Run with the required flags":
  exec "nimble --debugger:native --stacktrace:on --linetrace:on -d:debug --passC:-D_GNU_SOURCE -d:nimNoLentIterators run -- " & commandLineParams.join(" ")

task allFiles, "Save all files content to file all_files.txt":
  let ignoredPathes = @["./bin/*", "./.git/*"]
  let ignoredNames  = @["all_files.txt", "gitchanges.txt", "LICENSE", "secrets.nim", "nimble.paths", "state.json"]
  
  var pathFilters = ""
  for p in ignoredPathes:
    pathFilters &= " -not -path \"" & p & "\""
  
  var nameFilters = ""
  for n in ignoredNames:
    nameFilters &= " -not -name \"" & n & "\""
  
  let cmd = "find . -type f" & pathFilters & nameFilters & " -exec sh -c 'echo \"=== Файл: {} ===\" && cat {} && echo \"\"' \\; > all_files.txt"
  
  exec cmd

task gitChanges, "Save all changes to file gitchanges.txt":
  exec "git diff > gitchanges.txt"
