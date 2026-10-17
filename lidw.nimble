# Package

version       = "0.1.0"
author        = "xlebore3o4ka"
description   = "-"
license       = "AGPL-3.0"
srcDir        = "src"
binDir        = "bin"
bin           = @["lidw"]


# Dependencies

requires "nim >= 2.2.10"

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
