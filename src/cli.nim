import std/[parseopt, strformat, strutils]

const defaultServerHost* = "127.0.0.1"
const defaultServerPort* = 8080

type
  Command* = enum
    commandBuild
    commandServe
    commandDag
    commandNewsite
    commandVersion

  ServerOptions* = object
    host*: string
    port*: int

  CliConfig* = object
    command*: Command
    buildDrafts*: bool
    showHelp*: bool
    showVersion*: bool
    newsiteName*: string
    server*: ServerOptions

  CliError* = object of CatchableError

proc cliError(message: string): ref CliError =
  newException(CliError, message)

proc commandName(command: Command): string =
  case command
  of commandBuild: "build"
  of commandServe: "serve"
  of commandDag: "dag"
  of commandNewsite: "newsite"
  of commandVersion: "version"

proc parsePort(value: string): int =
  try:
    result = parseInt(value)
  except ValueError:
    raise cliError(&"Invalid port: {value}")
  if result < 1 or result > 65535:
    raise cliError(&"Port must be between 1 and 65535: {value}")

proc parseHost(value: string): tuple[host: string, port: int, hasPort: bool] =
  if value.startsWith("["):
    let close = value.find(']')
    if close < 0:
      raise cliError(&"Invalid host: {value}")
    result.host = value[1 ..< close]
    if result.host == "":
      raise cliError(&"Invalid host: {value}")
    let suffix = value[close + 1 .. ^1]
    if suffix != "":
      if not suffix.startsWith(":"):
        raise cliError(&"Invalid host: {value}")
      result.port = parsePort(suffix[1 .. ^1])
      result.hasPort = true
    return

  if value.count(':') == 1:
    let separator = value.find(':')
    result.host = value[0 ..< separator]
    if result.host == "":
      raise cliError(&"Invalid host: {value}")
    result.port = parsePort(value[separator + 1 .. ^1])
    result.hasPort = true
  else:
    result.host = value

  if result.host == "":
    raise cliError(&"Invalid host: {value}")

proc parseCli*(args: seq[string]): CliConfig =
  result.command = commandBuild
  result.server = ServerOptions(host: defaultServerHost, port: defaultServerPort)

  var parser = initOptParser(args, shortNoVal = {'D', 'V', 'h'},
      longNoVal = @[
        "buildDrafts", "help", "version"
      ], mode = LaxMode)
  var positional: seq[string] = @[]
  var commandSet = false
  var helpCommand = false
  var hostSet = false
  var portSet = false

  while true:
    parser.next()
    case parser.kind
    of cmdEnd:
      break
    of cmdArgument:
      positional.add(parser.key)
      if not commandSet:
        let normalized = parser.key.toLowerAscii()
        case normalized
        of "", "build": result.command = commandBuild
        of "serve", "server": result.command = commandServe
        of "dag": result.command = commandDag
        of "newsite": result.command = commandNewsite
        of "version": result.command = commandVersion
        of "help":
          result.command = commandBuild
          helpCommand = true
        else:
          raise cliError(&"Unknown command: {parser.key}\nTry 'hunim --help' for usage.")
        commandSet = true
    of cmdShortOption, cmdLongOption:
      let key = parser.key
      case key
      of "h", "help": result.showHelp = true
      of "V", "version": result.showVersion = true
      of "D", "buildDrafts": result.buildDrafts = true
      of "p", "port":
        if parser.val == "":
          raise cliError("Missing value for --port")
        result.server.port = parsePort(parser.val)
        portSet = true
      of "host":
        if parser.val == "":
          raise cliError("Missing value for --host")
        let parsedHost = parseHost(parser.val)
        result.server.host = parsedHost.host
        if parsedHost.hasPort and not portSet:
          result.server.port = parsedHost.port
        hostSet = true
      else:
        raise cliError(&"Unknown option: --{key}\nTry 'hunim --help' for usage.")

  if helpCommand:
    if positional.len > 2:
      raise cliError("Usage: hunim help [command]")
    if positional.len == 2:
      let target = positional[1].toLowerAscii()
      case target
      of "", "build": result.command = commandBuild
      of "serve", "server": result.command = commandServe
      of "dag": result.command = commandDag
      of "newsite": result.command = commandNewsite
      of "version": result.command = commandVersion
      else:
        raise cliError(&"Unknown command: {positional[1]}\nTry 'hunim --help' for usage.")
    result.showHelp = true

  if result.showHelp or result.showVersion:
    return

  if (hostSet or portSet) and result.command != commandServe:
    raise cliError("--host and --port are only valid with 'hunim serve'")

  if result.command == commandNewsite:
    if positional.len != 2:
      raise cliError("Usage: hunim newsite <name>")
    result.newsiteName = positional[1]
  elif positional.len > 1:
    raise cliError(&"Unexpected argument: {positional[1]}")

proc helpText*(command: Command = commandBuild): string =
  case command
  of commandBuild:
    result = """Hunim - a small static site generator written in Nim

Usage:
  hunim [options] [command]

Commands:
  build       Build the site (the default command)
  serve       Run the development server (server is an alias)
  dag         Serve the dependency graph viewer
  newsite     Create a new site directory
  version     Print the installed version
  help        Show help for a command

Options:
  -h, --help       Show this help
  -V, --version    Show the version
  -D, --buildDrafts Include draft pages in the build

Use 'hunim <command> --help' or 'hunim help <command>' for command-specific help.
"""
  of commandServe:
    result = &"""Run the development server with hot reload.

Usage:
  hunim serve [options]

Options:
  --host <address[:port]> Bind address (default: {defaultServerHost}); optional port
  -p, --port <port> Bind port (default: {defaultServerPort})
  -D, --buildDrafts Include draft pages
  -h, --help        Show this help
"""
  of commandDag:
    result = """Serve an interactive dependency graph viewer.

Usage:
  hunim dag

Options:
  -h, --help  Show this help
"""
  of commandNewsite:
    result = """Create a new site directory.

Usage:
  hunim newsite <name>

Options:
  -h, --help  Show this help
"""
  of commandVersion:
    result = """Print the installed version.

Usage:
  hunim --version
  hunim version
"""

proc commandName*(config: CliConfig): string = commandName(config.command)
