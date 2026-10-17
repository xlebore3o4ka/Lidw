# Embedded version string, read from VERSION at compile time.
# <NOTE>#5: VERSION is the single source of truth; do not hardcode elsewhere.

import std/strutils

const LidwVersion* = staticRead("../VERSION").strip()
