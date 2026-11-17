# Package
version       = "0.6.2"
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

task makewinarm, "Cross-compile to Windows ARM64 (requires llvm-mingw)":
  if not dirExists("lib"):
    mkDir("lib")
  if not dirExists("lib/md4c"):
    exec "git clone https://github.com/mity/md4c lib/md4c"

  exec "nim c -d:danger --opt:size --panics:on --passC:-flto --passL:-flto --passL:-static --passC:-Ilib/md4c/src " &
       "--os:windows --cpu:arm64 --cc:clang " &
       "--clang.exe:aarch64-w64-mingw32-clang " &
       "--clang.linkerexe:aarch64-w64-mingw32-clang " &
       "--out:hunim.exe src/main.nim"
  exec "llvm-strip -s hunim.exe"

task bin, "Put binary in ~/bin/":
  exec "cp hunim ~/bin/"
  echo "Put hunim in ~/bin/"
