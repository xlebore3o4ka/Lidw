# Resolve type name (as written in source) to LidwType.
# <NOTE>#18: single place for type-name aliases; extend here when new
# aliases appear. Position for the error is supplied by the caller.

import ./types
import ./errors

proc resolveTypeName*(name: string, line, col: int): LidwType =
  case name
  of "Int", "I64": i64Type()
  of "I8": i8Type()
  of "U8": u8Type()
  of "I16": i16Type()
  of "U16": u16Type()
  of "I32": i32Type()
  of "U32": u32Type()
  of "U64": u64Type()
  of "Bool": boolType()
  of "Nul": nulType()
  of "Float", "F64": f64Type()
  of "F32": f32Type()

  else:

    raise lidwError(lekSema, "unknown type: " & name, line, col)
