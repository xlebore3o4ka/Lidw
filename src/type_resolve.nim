# Resolve type name (as written in source) to LidwType.
# <NOTE>#18: single place for type-name aliases; extend here when new
# aliases appear. Position for the error is supplied by the caller.

import ./types
import ./errors

proc resolveTypeName*(name: string, line, col: int): LidwType =
  case name
  of "Int", "I64": i64Type()
  of "Bool": boolType()
  else:
    raise lidwError(lekSema, "unknown type: " & name, line, col)
