mode = ScriptMode.Silent

import std/strutils

for line in readFile("../hunim.nimble").splitLines():
  if line.startsWith("version"):
    echo line.split('"')[1]
    break
