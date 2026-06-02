# Package
version       = "0.2.0"
author        = "WyattBlue"
description   = "Awesome static site generator for humans"
license       = "Unlicense"
srcDir        = "src"
bin           = @["main=hunim"]


# Dependencies
requires "nim >= 2.2.0"
requires "parsetoml"

before install:
  if not dirExists("lib"):
    mkDir("lib")
  if not dirExists("lib/md4c"):
    exec "git clone https://github.com/mity/md4c lib/md4c"

task make, "Export the project":
  if not dirExists("lib"):
    mkDir("lib")
  if not dirExists("lib/md4c"):
    exec "git clone https://github.com/mity/md4c lib/md4c"

  exec "nim c -d:danger --opt:size --panics:on --passC:-flto --passL:-flto --passC:-Ilib/md4c/src --out:hunim src/main.nim"
  when defined(macosx):
    exec "strip -ur hunim"
    exec "stat -f \"%z bytes\" ./hunim"
    echo ""
  when defined(linux):
    exec "strip -s hunim"

task bin, "Put binary in ~/bin/":
  exec "cp hunim ~/bin/"
  echo "Put hunim in ~/bin/"
