import std/[strutils, unittest]

import ../src/cli

suite "CLI parsing":
  test "bare invocation builds by default":
    let config = parseCli(@[])
    check config.command == commandBuild
    check config.server.host == defaultServerHost
    check config.server.port == defaultServerPort

  test "serve accepts host and port":
    let config = parseCli(@["serve", "--host", "0.0.0.0", "-p", "8081"])
    check config.command == commandServe
    check config.server.host == "0.0.0.0"
    check config.server.port == 8081

  test "host accepts an optional port":
    let config = parseCli(@["serve", "--host", "0.0.0.0:4545"])
    check config.server.host == "0.0.0.0"
    check config.server.port == 4545

    let ipv6 = parseCli(@["serve", "--host", "::1"])
    check ipv6.server.host == "::1"
    check ipv6.server.port == defaultServerPort

    let bracketed = parseCli(@["serve", "--host", "[::1]:4545"])
    check bracketed.server.host == "::1"
    check bracketed.server.port == 4545

  test "server remains an alias":
    check parseCli(@["server"]).command == commandServe

  test "help and version flags are recognized":
    check parseCli(@["--help"]).showHelp
    check parseCli(@["-h", "serve"]).showHelp
    check parseCli(@["--version"]).showVersion
    check parseCli(@["-V"]).showVersion

  test "command help selects the command":
    let config = parseCli(@["serve", "--help"])
    check config.command == commandServe
    check helpText(config.command).find("--port") >= 0

  test "help command selects a command":
    let config = parseCli(@["help", "serve"])
    check config.command == commandServe
    check config.showHelp

    let buildConfig = parseCli(@["help", "build"])
    check buildConfig.command == commandBuild
    check buildConfig.showHelp
    check helpText(buildConfig.command).find("--buildDrafts") >= 0

  test "invalid ports are rejected":
    expect CliError:
      discard parseCli(@["serve", "--port", "banana"])
    expect CliError:
      discard parseCli(@["serve", "--port", "0"])
    expect CliError:
      discard parseCli(@["serve", "--port", "65536"])

  test "unknown commands and options are rejected":
    expect CliError:
      discard parseCli(@["unknown"])
    expect CliError:
      discard parseCli(@["--wat"])

  test "server options require serve":
    expect CliError:
      discard parseCli(@["build", "--port", "8081"])
