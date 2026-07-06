import std/[algorithm, atomics, json, sequtils, sets, strformat, strutils,
    terminal, times, os, osproc, tables, typedthreads, mimetypes, xmltree]
import std/[asynchttpserver, asyncdispatch, uri]

import ./[about, md4c_wrapper, highlight, dag]

import parsetoml


# Global caches for templates and components
var templateCache = initTable[string, string]()
var componentCache = initTable[string, string]()
# Caches the stdout of each {{ exec script.nims }} by script name, so a script
# runs at most once per build no matter how many tags reference it (within a
# page or across the whole site).
var execCache = initTable[string, string]()
# Maps a feed directory (e.g. "public/blog") to its feed title, so feed pages
# can advertise their RSS feed via <link rel="alternate">.
var feedRegistry = initTable[string, string]()
# Maps a feed directory (e.g. "public/blog") to the generated HTML list of its
# posts, which is injected into the feed's index page via {{ .PostList }}.
var feedPostLists = initTable[string, string]()
var buildDrafts = false
# When keepMarkdown is set (via the [markdown] table in hunim.toml), each page's
# source Markdown is published alongside its HTML at the same route with a .md
# extension (e.g. /docs/getting-started.md), instead of being deleted after
# conversion. stripFrontmatter drops the leading `---` block; expandTags runs
# the component/{{ .Var }}/exec passes over the body (skipping code samples).
var keepMarkdown = false
var mdStripFrontmatter = true
var mdExpandTags = true
# Build-time syntax highlighting of fenced code blocks (see highlight.nim).
# Disabled via [highlight] enabled = false, e.g. for a client-side highlighter.
var highlightCode = true
# Site config from hunim.toml, set by main(). Kept as globals so the dev
# server's partial rebuilds can convert single pages without re-reading the
# config (a hunim.toml change always takes the full-rebuild path).
var siteBaseUrl = ""
var siteLang = ""

let reloadScript = """<script>var bfr = '';
  setInterval(function () {
      fetch(window.location).then((response) => {
          return response.text();
      }).then(r => {
          if (bfr != '' && bfr != r) {
              setTimeout(function() {
                  window.location.reload();
              }, 100);
          }
          else {
              bfr = r;
          }
      });
  }, 100);
</script>"""


proc ctrlc() {.noconv.} =
  echo ""
  quit(1)

setControlCHook(ctrlc)

proc error(msg: string) =
  stderr.styledWriteLine(fgRed, bgBlack, msg, resetStyle)
  quit(1)

proc warn(msg: string) =
  stderr.styledWriteLine(fgYellow, msg, resetStyle)

func toUnixPath(path: string): string =
  ## Normalize OS path separators to '/'. On Windows, walkDir/walkFiles and the
  ## `/` operator emit '\', but the URL- and prefix-rewriting throughout the
  ## build (stripping "public/", testing for "/index.html", splitting feed dirs)
  ## assumes '/'. Windows file APIs also accept '/', so normalizing paths as they
  ## enter that logic keeps the string surgery correct on every platform.
  when DirSep == '\\':
    path.replace('\\', '/')
  else:
    path

proc loadTemplates() =
  ## Load all templates from the templates directory into cache
  templateCache.clear()
  if not dirExists("templates"):
    return

  for kind, tmpl in walkDir("templates"):
    let tmplName = tmpl.extractFilename()
    if kind == pcFile and not tmplName.startsWith("."):
      templateCache[tmplName] = readFile(tmpl)

proc parseDate(date: string): DateTime =
  # Parse RFC 2822 dates

  let explode = rsplit(date, " ", 1)
  if explode.len < 2:
    error &"Invalid date (expected 'ddd, dd MMM yyyy HH:mm:ss ZZZ'): \"{date}\""
  let date2 = explode[0]
  let timezone = explode[1]

  result = parse(date2, "ddd, dd MMM yyyy HH:mm:ss")
  case timezone:
    of "EDT": result -= initDuration(hours = -4)
    of "EST": result -= initDuration(hours = -5)
    of "CDT": result -= initDuration(hours = -5)
    of "CST": result -= initDuration(hours = -6)
    of "MDT": result -= initDuration(hours = -6)
    of "MST": result -= initDuration(hours = -7)
    of "PDT": result -= initDuration(hours = -7)
    of "PST": result -= initDuration(hours = -8)
    of "AKDT": result -= initDuration(hours = -8)
    of "AKST": result -= initDuration(hours = -9)
    of "HST": result -= initDuration(hours = -10)
    of "UTC": discard
    else: error &"Unknown time zone: {timezone}"

  return result

# Hunim never expands `{{ … }}` directives inside <pre>/<code> regions, so
# documentation can show literal template, component, and exec tags in code
# samples without the build substituting them. The helpers below split content
# into code and non-code spans; the three expansion passes run only over the
# non-code spans.

# A `<pre>`/`<code>` tag name must be followed by one of these so we don't trip
# on `<predicate>` or `<codex>`.
const tagBoundary = {'>', ' ', '\t', '\n', '\r', '/'}

func htmlCodeOpenAt(content: string, i: int): string =
  ## If a `<pre>` or `<code>` opening tag begins exactly at `i`, return its
  ## closing tag; otherwise "".
  if i >= content.len or content[i] != '<':
    return ""
  if content.continuesWith("pre", i + 1) and
      (i + 4 >= content.len or content[i + 4] in tagBoundary):
    return "</pre>"
  if content.continuesWith("code", i + 1) and
      (i + 5 >= content.len or content[i + 5] in tagBoundary):
    return "</code>"
  return ""

func nextCodeRegion(content: string, start: int): tuple[open: int,
    closeTag: string] =
  ## Locate the next <pre>/<code> opening tag at or after `start`.
  ## Returns open = -1 when there is none.
  var i = start
  while true:
    let lt = content.find('<', i)
    if lt == -1:
      return (-1, "")
    let closeTag = htmlCodeOpenAt(content, lt)
    if closeTag != "":
      return (lt, closeTag)
    i = lt + 1

iterator codeSegments(content: string): tuple[isCode: bool, text: string] =
  ## Split `content` into alternating non-code and <pre>/<code> spans. A <pre>
  ## fully encloses its inner <code>, so matching its own closing tag keeps the
  ## whole block in a single verbatim span.
  var i = 0
  while i < content.len:
    let region = nextCodeRegion(content, i)
    if region.open == -1:
      yield (false, content[i .. ^1])
      break
    if region.open > i:
      yield (false, content[i ..< region.open])
    let closeIdx = content.find(region.closeTag, region.open)
    if closeIdx == -1:
      # Unclosed region: keep the remainder verbatim rather than risk expanding
      # a partially shown tag.
      yield (true, content[region.open .. ^1])
      break
    let endIdx = closeIdx + region.closeTag.len
    yield (true, content[region.open ..< endIdx])
    i = endIdx

# The Markdown counterpart to codeSegments. codeSegments protects code in the
# *converted HTML* (where samples are <pre>/<code>); when we emit a page's raw
# Markdown rendition we must instead protect code in its *source* form — fenced
# ``` / ~~~ blocks and inline `spans` — plus any literal HTML <pre>/<code> the
# author wrote. Otherwise expanding tags would turn a documented `{{ nav }}`
# example into the actual rendered component.

func isMdLineStart(content: string, i: int): bool =
  ## True when only blanks separate `i` from the previous newline, so a fence
  ## marker at `i` opens a line. (CommonMark allows up to 3 leading spaces; we
  ## accept any blank run since stray indentation here is harmless.)
  var j = i - 1
  while j >= 0 and content[j] in {' ', '\t'}:
    dec j
  return j < 0 or content[j] == '\n'

func runLength(content: string, i: int, ch: char): int =
  ## Count of consecutive `ch` starting at `i`.
  var j = i
  while j < content.len and content[j] == ch:
    inc j
  return j - i

func lineEnd(content: string, i: int): int =
  ## Index just past the newline ending the line containing `i` (or content.len).
  let nl = content.find('\n', i)
  return (if nl == -1: content.len else: nl + 1)

func fencedBlockEnd(content: string, openStart: int, marker: char,
    openLen: int): int =
  ## Given an opening fence at `openStart`, return the index just past the
  ## closing fence line, or content.len if the block is never closed.
  var i = lineEnd(content, openStart)
  while i < content.len:
    var j = i
    while j < content.len and content[j] in {' ', '\t'}:
      inc j
    if j < content.len and content[j] == marker and
        runLength(content, j, marker) >= openLen:
      # A closing fence may carry trailing whitespace but no other text.
      var k = j + runLength(content, j, marker)
      while k < content.len and content[k] in {' ', '\t'}:
        inc k
      if k >= content.len or content[k] == '\n':
        return lineEnd(content, i)
    i = lineEnd(content, i)
  return content.len

func inlineCodeEnd(content: string, openStart, runLen: int): int =
  ## Given an inline code span opening with `runLen` backticks at `openStart`,
  ## return the index just past the matching closing run, or -1 if unmatched
  ## (in which case the backticks are literal text, per CommonMark).
  var i = openStart + runLen
  while i < content.len:
    if content[i] == '`':
      let rl = runLength(content, i, '`')
      if rl == runLen:
        return i + rl
      i += rl
    else:
      inc i
  return -1

iterator mdCodeSegments(content: string): tuple[isCode: bool, text: string] =
  ## Split raw Markdown into alternating non-code and code spans, where code is
  ## an HTML <pre>/<code> region, a fenced ``` / ~~~ block, or an inline `span`.
  var segStart = 0
  var i = 0
  while i < content.len:
    let c = content[i]
    var codeEnd = -1

    if (c == '`' or c == '~') and isMdLineStart(content, i) and
        runLength(content, i, c) >= 3:
      codeEnd = fencedBlockEnd(content, i, c, runLength(content, i, c))
    else:
      let closeTag = htmlCodeOpenAt(content, i)
      if closeTag != "":
        let closeIdx = content.find(closeTag, i)
        codeEnd = (if closeIdx == -1: content.len else: closeIdx + closeTag.len)
      elif c == '`':
        codeEnd = inlineCodeEnd(content, i, runLength(content, i, '`'))

    if codeEnd != -1:
      if i > segStart:
        yield (false, content[segStart ..< i])
      yield (true, content[i ..< codeEnd])
      segStart = codeEnd
      i = codeEnd
    else:
      inc i

  if segStart < content.len:
    yield (false, content[segStart ..< content.len])

proc nonCodeText(content: string, isMd: bool): string =
  ## The text with code regions removed, so tags the build leaves literal
  ## (documentation code samples) don't count as references.
  if isMd:
    for seg in mdCodeSegments(content):
      if not seg.isCode: result &= seg.text
  else:
    for seg in codeSegments(content):
      if not seg.isCode: result &= seg.text

proc findComponentRefs(text: string, names: seq[string]): seq[string] =
  for name in names:
    let pat = "{{ " & name
    var idx = 0
    while true:
      let f = text.find(pat, idx)
      if f == -1:
        break
      # Require a space after the name so `nav` doesn't match `{{ navbar }}`.
      if f + pat.len < text.len and text[f + pat.len] == ' ':
        result.add(name)
        break
      idx = f + 1

proc findExecRefs(text: string): seq[string] =
  var idx = 0
  while true:
    let openIdx = text.find("{{ exec ", idx)
    if openIdx == -1:
      return
    let closeIdx = text.find(" }}", openIdx)
    if closeIdx == -1:
      return
    let name = text[openIdx + 8 .. closeIdx - 1].strip()
    if name.endsWith(".nims") and name notin result:
      result.add(name)
    idx = closeIdx + 3

proc parseTemplateSegment(content: string, compName: string,
    compContent: string): string =
  var newContent = content
  var startIdx = 0
  while true:
    let openIdx = newContent.find("{{ " & compName, startIdx)
    if openIdx == -1:
      break
    let closeIdx = newContent.find(" }}", openIdx)
    if closeIdx == -1 and openIdx != -1:
      stderr.writeLine("error! Unclosed template for " & compName)
      quit(1)
    if closeIdx == -1:
      break

    # In Markdown pages, components are parsed after Markdown conversion, which
    # escapes the argument quotes to `&quot;`. Normalize that back to `"` so the
    # delimiter split works the same as in raw HTML pages and templates.
    let argsStr = newContent[openIdx + compName.len + 3 .. closeIdx - 1]
        .strip().replace("&quot;", "\"")
    let args = argsStr.split('"').filterIt(it.strip() != "")

    var replacedContent = compContent
    for i, arg in args:
      replacedContent = replacedContent.replace("{{ $" & $(i+1) & " }}", arg)

    # Replace only this matched span; replacing all occurrences of the match
    # text would desync startIdx and mishandle repeated invocations.
    newContent = newContent[0 ..< openIdx] & replacedContent &
        newContent[closeIdx + 3 .. ^1]
    startIdx = openIdx + replacedContent.len

  return newContent

proc parseTemplate(content: string, compName: string,
    compContent: string): string =
  ## Expand `{{ compName … }}` invocations, leaving any inside <pre>/<code>
  ## (e.g. documentation code samples) untouched.
  for seg in codeSegments(content):
    result &= (if seg.isCode: seg.text
               else: parseTemplateSegment(seg.text, compName, compContent))

proc loadComponents() =
  ## Load all components into cache, with nested component references already
  ## expanded. Components are resolved dependencies-first, so a component may
  ## freely reference other components regardless of load order; what the cache
  ## holds is fully expanded. Component references must be acyclic — a cycle is
  ## a build error.
  componentCache.clear()
  if not dirExists("components"):
    return

  var raw = initTable[string, string]()
  var names: seq[string] = @[]
  for kind, comp in walkDir("components"):
    let compName = comp.extractFilename().changeFileExt("")
    if kind == pcFile and not compName.startsWith("."):
      raw[compName] = readFile(comp).strip()
      names.add(compName)

  # `stack` is the current depth-first resolution path; meeting a component
  # that is already on it means the references form a cycle.
  var stack: seq[string] = @[]

  proc resolve(name: string) =
    if componentCache.hasKey(name):
      return
    if name in stack:
      error "Component cycle: " &
          (stack[stack.find(name) .. ^1] & name).join(" -> ")
    stack.add(name)
    var content = raw[name]
    for dep in findComponentRefs(nonCodeText(content, isMd = false), names):
      resolve(dep)
      content = parseTemplate(content, dep, componentCache[dep])
    discard stack.pop()
    componentCache[name] = content

  for name in names:
    resolve(name)

proc renderTemplate(templateContent: string, context: Table[string,
    string]): string =
  ## Render a Go-style template by replacing {{ .Key }} with context values,
  ## skipping any inside <pre>/<code> so documented tags stay literal. Each key
  ## re-scans the current result, so content injected by an earlier key (e.g.
  ## the page body via {{ .Content }}) is protected too.
  result = templateContent
  for key, value in context:
    let tag = "{{ ." & key & " }}"
    var rebuilt = ""
    for seg in codeSegments(result):
      rebuilt &= (if seg.isCode: seg.text else: seg.text.replace(tag, value))
    result = rebuilt

proc processExecTagsSegment(content: string): string =
  var newContent = content
  var startIdx = 0
  while true:
    let openIdx = newContent.find("{{ exec ", startIdx)
    if openIdx == -1:
      break
    let closeIdx = newContent.find(" }}", openIdx)
    if closeIdx == -1:
      stderr.writeLine("error! Unclosed exec tag")
      quit(1)

    let scriptName = newContent[openIdx + 8 .. closeIdx - 1].strip()

    if not scriptName.endsWith(".nims"):
      error &"exec script must end with .nims: {scriptName}"
    for c in scriptName[0..^6]:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
        error &"exec script name contains invalid characters: {scriptName}"

    var trimmed: string
    if execCache.hasKey(scriptName):
      trimmed = execCache[scriptName]
    else:
      let scriptPath = "components" / scriptName

      if not fileExists(scriptPath):
        error &"NimScript not found: {scriptPath}"

      let (output, exitCode) = execCmdEx(
          "nim e --hints:off " & quoteShell(scriptPath))
      if exitCode != 0:
        error &"NimScript failed ({scriptName}):\n{output}"

      trimmed = output.strip()
      execCache[scriptName] = trimmed

    let fullMatch = newContent[openIdx .. closeIdx + 2]
    newContent = newContent.replace(fullMatch, trimmed)
    startIdx = openIdx + trimmed.len

  return newContent

proc processExecTags(content: string): string =
  ## Replace {{ exec script.nims }} tags with the script's stdout, skipping any
  ## inside <pre>/<code> so documented tags stay literal.
  for seg in codeSegments(content):
    result &= (if seg.isCode: seg.text else: processExecTagsSegment(seg.text))

proc expandExecInMarkdown(content: string): string =
  ## Expand {{ exec }} tags in a raw Markdown body before the Markdown→HTML
  ## conversion, skipping code regions (fences, inline spans, raw <pre>/<code>)
  ## so documented tags stay literal. Running exec here — rather than on the
  ## converted HTML — lets a script that emits Markdown be rendered as part of
  ## the page instead of injected verbatim into the already-rendered HTML.
  for seg in mdCodeSegments(content):
    result &= (if seg.isCode: seg.text else: processExecTagsSegment(seg.text))

proc processFile(path: string, baseUrl: string, doReload: bool, lang: string): string =
  # Skip non-HTML files
  let ext = path.splitFile().ext.toLowerAscii()
  if ext != ".html":
    return ""

  var content = readFile(path)

  # Use cached components instead of reading from disk
  for compName, compContent in componentCache:
    content = parseTemplate(content, compName, compContent)

  # Render template variables like {{ .Lang }}
  var context = initTable[string, string]()
  context["Lang"] = lang
  content = renderTemplate(content, context)
  content = processExecTags(content)

  # Inject the dev-server auto-reload script before `</head>` (only when serving;
  # production builds get nothing). `{{ .Reload }}` is a legacy placeholder that
  # is no longer documented, but we still resolve it so older templates that
  # contain it don't leak the literal text into the page.
  if content.contains("{{ .Reload }}"):
    content = content.replace("{{ .Reload }}", (if doReload: reloadScript else: ""))
  elif doReload:
    content = content.replace("</head>", reloadScript & "\n</head>")

  var outputPath = path
  var wasRenamed = false
  if path.endsWith("index.html"):
    outputPath = path
  elif path.endsWith(".html"):
    outputPath = path.splitFile().dir / path.splitFile().name
    wasRenamed = true

  writeFile(outputPath, content)

  if outputPath != path:
    removeFile(path)
  #   echo "Processed and renamed: ", path, " -> ", outputPath
  # else:
  #   echo "Processed: ", path

  # Only add to sitemap if this is an index.html file
  # Non-index HTML files that get renamed were generated from markdown
  # and already added to sitemap during conversion
  if wasRenamed:
    return ""

  # Check if page has noindex meta tag
  if content.contains("<meta name=\"robots\" content=\"noindex\">"):
    return ""

  # Generate URL for sitemap
  var url = outputPath.replace("public/", "")
  if url.endsWith("/index.html"):
    url = url.replace("/index.html", "")
  elif url == "index.html":
    url = ""
  elif url.endsWith(".html"):
    url = url[0..^6] # Remove .html extension

  return baseUrl & url

proc processDirectory(dir: string, baseUrl: string, urls: var seq[string], doReload: bool, lang: string) =
  for kind, path in walkDir(dir):
    let path = toUnixPath(path)
    if kind == pcFile:
      let url = processFile(path, baseUrl, doReload, lang)
      if url != "":
        urls.add(url)
    elif kind == pcDir:
      processDirectory(path, baseUrl, urls, doReload, lang)

type BlogPost = object
  title: string
  link: string
  desc: string
  path: string      # For sorting by date
  pubDate: string
  dateObj: DateTime # For sorting

proc parseFrontmatter(file: string): Table[string, string] =
  ## Parse optional `---`-delimited frontmatter into key/value pairs. Each line
  ## is `key: value`; only the first colon splits, so values may contain colons
  ## (e.g. RFC 2822 dates). A file with no leading `---` has no metadata.
  let lines = readFile(file).splitLines()
  if lines.len == 0 or lines[0].strip() != "---":
    return

  var i = 1
  while i < lines.len and lines[i].strip() != "---":
    let colon = lines[i].find(':')
    if colon == -1:
      error &"{file}: frontmatter: expected 'key: value'"
    result[lines[i][0 ..< colon].strip()] = lines[i][colon + 1 .. ^1].strip()
    inc i
  if i >= lines.len:
    error &"{file}: frontmatter: missing closing ---"

proc titleFromFilename(file: string): string =
  ## Derive a display title from a filename when a page has no `title`
  ## frontmatter, e.g. "my-cool-post.md" -> "My Cool Post".
  let words = file.splitFile().name.replace("-", " ").splitWhitespace()
  return words.mapIt(it.capitalizeAscii()).join(" ")

proc titleOf(file: string, frontmatter: Table[string, string]): string =
  ## The page title: the `title` frontmatter if present, else derived from the
  ## filename.
  frontmatter.getOrDefault("title", titleFromFilename(file))

proc extractMetadata(baseUrl, file: string,
    frontmatter: Table[string, string]): BlogPost =
  if not file.startsWith("public/"):
    error &"Expected post path under public/: {file}"

  let urlPath = file[7..<file.len].changeFileExt("")
  let date = frontmatter.getOrDefault("date", "")

  return BlogPost(
    title: titleOf(file, frontmatter),
    link: &"{baseUrl}{urlPath}",
    desc: frontmatter.getOrDefault("desc", ""),
    path: file,
    pubDate: date,
    dateObj: parseDate(date),
  )

proc nonFrontmatter(file: string): string =
  ## Return the file body with any `---`-delimited frontmatter removed. A file
  ## without a leading `---` is returned whole.
  let text = readFile(file)
  let lines = text.splitLines()
  if lines.len == 0 or lines[0].strip() != "---":
    return text

  var i = 1
  while i < lines.len and lines[i].strip() != "---":
    inc i
  if i >= lines.len:
    error &"{file}: frontmatter: missing closing ---"
  return lines[i + 1 .. ^1].join("\n")

proc formatDisplayDate(date: string): string =
  ## Format an RFC 2822 date as "Month d, yyyy" for display.
  try:
    # Try to parse RFC 2822 format with timezone abbreviation
    let parsedDate = parse(date, "ddd, dd MMM yyyy HH:mm:ss zzz")
    format(parsedDate, "MMMM d, yyyy")
  except CatchableError:
    # Fall back to just the date part, e.g. "29 Jul 2024"
    let parts = date.split(" ")
    if parts.len < 4:
      error &"Invalid date (expected 'ddd, dd MMM yyyy ...'): \"{date}\""
    let datePart = parts[1..3].join(" ")
    let parsedDate = parse(datePart, "dd MMM yyyy")
    format(parsedDate, "MMMM d, yyyy")

proc renderInline(text: string): string =
  ## Render inline markdown (e.g. backticks in a title) and strip the wrapping
  ## paragraph so it can be embedded inside another element.
  result = markdown(text).strip()
  if result.startsWith("<p>") and result.endsWith("</p>"):
    result = result[3 ..< result.len - 4].strip()

proc collectPosts(baseUrl, inputPath: string): seq[BlogPost] =
  ## Collect all blog posts in a feed directory, sorted newest first.
  for file in walkFiles(inputPath / "*.md"):
    let file = toUnixPath(file)
    if file.endsWith("index.md"):
      continue

    let frontmatter = parseFrontmatter(file)
    if not buildDrafts and frontmatter.getOrDefault("draft", "false") == "true":
      continue

    let post = extractMetadata(baseUrl, file, frontmatter)
    # Posts opting out of indexing are excluded from the feed and post list.
    if post.desc == "no-index":
      continue
    result.add(post)

  # Sort posts by date (newest first)
  result.sort(proc (x, y: BlogPost): int =
    # Compare dates in reverse order for newest first
    cmp(y.dateObj, x.dateObj)
  )

proc generatePostList(baseUrl: string, posts: seq[BlogPost]): string =
  ## Build the HTML list of blog posts injected into a feed's index page.
  var lines: seq[string] = @[]
  for post in posts:
    let href = post.link.replace(baseUrl, "/")
    let displayDate = formatDisplayDate(post.pubDate)
    lines.add(&"<p><a href=\"{href}\">{renderInline(post.title)}</a> {displayDate}</p>")
  return lines.join("\n")

proc generateRSSFeed(frontmatter: Table[string, string], lang, baseUrl,
    outputPath: string, posts: seq[BlogPost]) =
  let title = xmltree.escape(frontmatter.getOrDefault("title", "RSS Feed"))
  let desc = xmltree.escape(frontmatter.getOrDefault("desc", "My RSS Feed"))
  let link = xmltree.escape(baseUrl)

  # The feed's own canonical URL, advertised via <atom:link rel="self">.
  let selfUrl = xmltree.escape(baseUrl & outputPath.replace("public/", ""))

  # Generate RSS XML
  var rssContent = &"""<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:atom="http://www.w3.org/2005/Atom" version="2.0">
  <channel>
    <title>{title}</title>
    <link>{link}</link>
    <atom:link href="{selfUrl}" rel="self" type="application/rss+xml"/>
    <description>{desc}</description>
    <language>{xmltree.escape(lang)}</language>
"""

  # Add items
  for post in posts:
    let summary =
      if post.desc != "": post.desc & " "
      else: ""
    let description = xmltree.escape(
      &"""{summary}<div style="margin-top: 50px; font-style: italic;"><strong><a href="{post.link}">Keep reading</a>.</strong></div>""")
    let itemTitle = xmltree.escape(post.title)
    let itemLink = xmltree.escape(post.link)
    let pubDate = xmltree.escape(post.pubDate)
    rssContent &= &"""    <item>
      <title>{itemTitle}</title>
      <link>{itemLink}</link>
      <guid>{itemLink}</guid>
      <pubDate>{pubDate}</pubDate>
      <description>{description}</description>
    </item>
"""

  # Close tags
  rssContent &= "  </channel>\n</rss>"

  # Write to file
  writeFile(outputPath, rssContent)
  echo "Generated RSS feed at: ", outputPath

proc writeSitemap(urls: seq[string], outputPath: string) =
  # Generate sitemap XML
  var sitemapContent = """<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
"""

  for url in urls:
    sitemapContent &= &"""  <url>
    <loc>{url}</loc>
  </url>
"""

  sitemapContent &= "</urlset>"

  # Write to file
  writeFile(outputPath, sitemapContent)
  echo "Generated sitemap at: ", outputPath


type ConvertJob = object
  doReload: bool
  baseUrl: string
  lang: string
  file: string
  path: string
  feedDir: string
  body: string  # Markdown body, frontmatter-stripped and {{ exec }}-expanded

type ConvertCtx = object
  jobs: ptr seq[ConvertJob]
  results: ptr seq[string]  # HTML output, one slot per job index
  next: ptr Atomic[int]     # shared cursor: the next job index to claim

proc convertMarkdownWorker(ctx: ConvertCtx) {.thread.} =
  ## Pool worker: claim job indices off the shared `next` cursor and convert each
  ## Markdown body to HTML, writing the result into that job's own results slot.
  ## The body has already had its {{ exec }} tags expanded (single-threaded,
  ## upstream) so a script that emits Markdown is rendered as part of the page.
  ## Component and variable tags are still expanded later, after the template is
  ## applied, so that — like exec — they are never run inside a code sample.
  ## Because each index is written by exactly one worker, the shared seq needs no
  ## per-element locking.
  while true:
    let i = ctx.next[].fetchAdd(1)
    if i >= ctx.jobs[].len:
      break
    # highlightCode is a plain bool set before the pool spawns, so this read
    # stays gcsafe.
    let html = markdown(ctx.jobs[][i].body)
    ctx.results[][i] = (if highlightCode: highlightCodeBlocks(html) else: html)

proc expandMarkdown(content: string, context: Table[string, string]): string =
  ## Expand component, {{ .Var }}, and {{ exec }} tags in raw Markdown, leaving
  ## code regions (see mdCodeSegments) untouched. Mirrors the HTML expansion
  ## pipeline so the emitted .md matches the page minus its template wrapper.
  var c = content
  for compName, compContent in componentCache:
    var rebuilt = ""
    for seg in mdCodeSegments(c):
      rebuilt &= (if seg.isCode: seg.text
                  else: parseTemplateSegment(seg.text, compName, compContent))
    c = rebuilt
  for key, value in context:
    let tag = "{{ ." & key & " }}"
    var rebuilt = ""
    for seg in mdCodeSegments(c):
      rebuilt &= (if seg.isCode: seg.text else: seg.text.replace(tag, value))
    c = rebuilt
  result = ""
  for seg in mdCodeSegments(c):
    result &= (if seg.isCode: seg.text else: processExecTagsSegment(seg.text))

proc writeMarkdownSource(job: ConvertJob, frontmatter: Table[string, string]) =
  ## Publish the page's Markdown rendition at its route. The source already sits
  ## at job.file — the same path the HTML is served from, with a .md extension —
  ## so we overwrite it in place rather than deleting it after conversion.
  var body =
    if mdStripFrontmatter: nonFrontmatter(job.file)
    else: readFile(job.file)
  if mdExpandTags:
    var context = initTable[string, string]()
    context["Lang"] = job.lang
    context["Title"] = titleOf(job.file, frontmatter)
    # Feed posts expose Date/Author in their templates; mirror that in the body.
    if job.feedDir != "" and frontmatter.hasKey("date"):
      context["Date"] = formatDisplayDate(frontmatter["date"])
      if frontmatter.hasKey("author"):
        context["Author"] = frontmatter["author"]
    body = expandMarkdown(body, context)
  writeFile(job.file, body)

proc processConvertedMarkdown(job: ConvertJob, htmlOutput: string): string =
  let frontmatter = parseFrontmatter(job.file)
  var templateFile = ""

  # Get template from the frontmatter, or use implicit template for feed posts
  if job.feedDir != "":
    # Extract directory name from feedDir (e.g., "public/myblog" -> "myblog")
    let dirName = job.feedDir.split('/')[^1]
    let implicitTemplate = dirName & "_list.html"
    let implicitTemplatePath = "templates" / implicitTemplate

    if fileExists(implicitTemplatePath):
      templateFile = implicitTemplate
    else:
      templateFile = frontmatter.getOrDefault("template", "default.html")
  else:
    templateFile = frontmatter.getOrDefault("template", "default.html")

  let desc = frontmatter.getOrDefault("desc", "")

  let templatePath = "templates" / templateFile
  let useTemplate = fileExists(templatePath)
  var htmlContent = htmlOutput

  # Fix relative links in index pages to use correct directory path
  if job.path.endsWith("/index.html"):
    let dir = job.path.replace("public/", "/").replace("/index.html", "/")
    htmlContent = htmlContent.replace("href=\"./", "href=\"" & dir)

  # Inject the generated list of posts into a feed's index page
  if job.path.endsWith("/index.html") and feedPostLists.hasKey(job.path.parentDir):
    let postList = feedPostLists[job.path.parentDir]
    htmlContent = htmlContent.replace("<p>{{ .PostList }}</p>", postList)
    htmlContent = htmlContent.replace("{{ .PostList }}", postList)

  # Prepare content for rendering
  var content = htmlContent

  # Prepare meta tags. Values are XML-escaped so titles/descriptions containing
  # ", &, < or > don't truncate the attribute or inject stray markup.
  var metaTags = ""
  let pageTitle = titleOf(job.file, frontmatter)
  if desc != "no-index" and pageTitle != "":
    metaTags &= &"\n  <meta property=\"og:title\" content=\"{xmltree.escape(pageTitle)}\">"

  if desc != "" and desc != "no-index":
    metaTags &= &"\n  <meta name=\"description\" content=\"{xmltree.escape(desc)}\">"

  var sitemapUrl = ""
  if desc != "no-index":
    var url = job.path.replace("public/", "")
    if url.endswith("/index.html"):
      url = url.replace("/index.html", "")
    else:
      url = url.replace(".html", "")
    let canonical = xmltree.escape(job.baseUrl & url)
    metaTags &= &"\n  <link rel=\"canonical\" href=\"{canonical}\">"
    metaTags &= &"\n  <meta property=\"og:url\" content=\"{canonical}\">"
    sitemapUrl = job.baseUrl & url

    var feedDir = job.feedDir
    if feedDir == "" and feedRegistry.hasKey(job.path.parentDir):
      feedDir = job.path.parentDir
    if feedRegistry.hasKey(feedDir):
      let feedTitle = xmltree.escape(feedRegistry[feedDir])
      let feedHref = xmltree.escape(job.baseUrl & feedDir.replace("public/", "") & "/index.xml")
      metaTags &= &"\n  <link rel=\"alternate\" type=\"application/rss+xml\" title=\"{feedTitle}\" href=\"{feedHref}\">"
  else:
    metaTags &= "\n  <meta name=\"robots\" content=\"noindex\">"

  # When the Markdown source is published alongside the HTML, advertise it as an
  # alternate representation. The href is derived from job.path (not the canonical
  # URL) so index pages map to /dir/index.md rather than /dir.md.
  if keepMarkdown:
    let mdUrl = xmltree.escape(
      job.baseUrl & job.path.replace("public/", "").replace(".html", ".md"))
    metaTags &= &"\n  <link rel=\"alternate\" type=\"text/markdown\" href=\"{mdUrl}\">"

  let f = open(job.path, fmWrite)

  if useTemplate:
    # Use cached template instead of reading from disk
    if not templateCache.hasKey(templateFile):
      error &"Template file not found in cache: {templateFile}"
    let templateContent = templateCache[templateFile]
    var context = initTable[string, string]()
    # A page without a `title` frontmatter falls back to a title derived from
    # its filename, so `{{ .Title }}` is never left as a literal placeholder.
    context["Title"] = titleOf(job.file, frontmatter)
    if job.feedDir != "" and frontmatter.hasKey("date"):
      context["Date"] = formatDisplayDate(frontmatter["date"])
      if frontmatter.hasKey("author"):
        context["Author"] = frontmatter["author"]

    context["Content"] = content
    context["Lang"] = job.lang
    context["MetaTags"] = metaTags

    let renderedHtml = processExecTags(renderTemplate(templateContent, context))
    f.write(renderedHtml)
  else:
    error "Expected template file"

  f.close()
  if keepMarkdown:
    writeMarkdownSource(job, frontmatter)
  else:
    removeFile(job.file)

  return sitemapUrl

# --- Site dependency scanning -------------------------------------------------
# Shared by `hunim dag`, the dev server's smart rebuilds, and the build's
# unused-file warnings. Scans src/, templates/, and components/ directly (no
# build required) into a model of who references whom. The scan mirrors the
# build's rules — the same template resolution (frontmatter `template`,
# implicit feed templates, default.html) and the same code-region protection,
# so tags shown literally in documentation code samples don't count as
# references.

proc looseFrontmatter(file: string): Table[string, string] =
  ## Lenient counterpart to parseFrontmatter: malformed lines are skipped
  ## rather than aborting, so the dev/dag servers stay up while a page is
  ## mid-edit.
  let lines = readFile(file).splitLines()
  if lines.len == 0 or lines[0].strip() != "---":
    return
  var i = 1
  while i < lines.len and lines[i].strip() != "---":
    let colon = lines[i].find(':')
    if colon != -1:
      result[lines[i][0 ..< colon].strip()] = lines[i][colon + 1 .. ^1].strip()
    inc i

type
  TagRefs = tuple[comps, scripts: seq[string]]
  PageScan = object
    path: string         # src path, e.g. "src/blog/post.md"
    templateFile: string # resolved template filename; "" for raw .html pages
    refs: TagRefs
    feedDir: string      # the .md page's src feed directory, or ""
  SiteScan = object
    compNames: seq[string]
    compPaths: Table[string, string] # component name -> source file path
    scriptNames: seq[string]         # e.g. "version.nims"
    templateNames: seq[string]
    compRefs: Table[string, TagRefs] # keyed by component name
    tmplRefs: Table[string, TagRefs] # keyed by template filename
    pages: seq[PageScan]

proc scanTagRefs(text: string, compNames: seq[string]): TagRefs =
  (comps: findComponentRefs(text, compNames), scripts: findExecRefs(text))

proc scanSite(): SiteScan =
  var s = SiteScan()

  if dirExists("components"):
    for kind, path in walkDir("components"):
      let path = toUnixPath(path)
      let fname = path.extractFilename()
      if kind != pcFile or fname.startsWith("."):
        continue
      if fname.endsWith(".nims"):
        s.scriptNames.add(fname)
      else:
        let name = fname.changeFileExt("")
        s.compNames.add(name)
        s.compPaths[name] = path

  if dirExists("templates"):
    for kind, path in walkDir("templates"):
      let fname = toUnixPath(path).extractFilename()
      if kind == pcFile and not fname.startsWith("."):
        s.templateNames.add(fname)

  for c in s.compNames:
    var refs = scanTagRefs(
        nonCodeText(readFile(s.compPaths[c]), isMd = false), s.compNames)
    refs.comps = refs.comps.filterIt(it != c)
    s.compRefs[c] = refs

  for t in s.templateNames:
    s.tmplRefs[t] = scanTagRefs(
        nonCodeText(readFile("templates" / t), isMd = false), s.compNames)

  proc walkPages(dir: string, isFeed: bool) =
    for kind, path in walkDir(dir):
      let path = toUnixPath(path)
      if kind == pcFile:
        let ext = path.splitFile().ext.toLowerAscii()
        if ext notin [".md", ".html"]:
          continue
        var page = PageScan(path: path)
        let isMd = ext == ".md"
        page.refs = scanTagRefs(nonCodeText(readFile(path), isMd), s.compNames)
        if isMd:
          if isFeed:
            page.feedDir = dir
          page.templateFile =
            looseFrontmatter(path).getOrDefault("template", "default.html")
          if isFeed and not path.endsWith("index.md"):
            let implicit = dir.split('/')[^1] & "_list.html"
            if implicit in s.templateNames:
              page.templateFile = implicit
        s.pages.add(page)
      elif kind == pcDir:
        let indexFile = path / "index.md"
        var isFeed2 = false
        if fileExists(indexFile):
          isFeed2 = looseFrontmatter(indexFile).getOrDefault("type", "") == "feed"
        walkPages(path, isFeed2)

  if dirExists("src"):
    walkPages("src", false)
  return s

proc reverseDeps(scan: SiteScan): Table[string, HashSet[string]] =
  ## Map each template, component, and script source file to the set of src
  ## pages that transitively depend on it.
  var compClosure = initTable[string, HashSet[string]]()

  proc closureOf(c: string, stack: var seq[string]): HashSet[string] =
    ## All files component `c` pulls in: its own file, its scripts, and the
    ## closures of the components it references (cycle-safe).
    if compClosure.hasKey(c):
      return compClosure[c]
    if c in stack:
      return initHashSet[string]()
    stack.add(c)
    var files = initHashSet[string]()
    files.incl(scan.compPaths[c])
    for sc in scan.compRefs[c].scripts:
      files.incl("components/" & sc)
    for c2 in scan.compRefs[c].comps:
      files.incl(closureOf(c2, stack))
    discard stack.pop()
    compClosure[c] = files
    return files

  proc filesFor(refs: TagRefs): HashSet[string] =
    var stack: seq[string] = @[]
    for c in refs.comps:
      result.incl(closureOf(c, stack))
    for sc in refs.scripts:
      result.incl("components/" & sc)

  for page in scan.pages:
    var files = filesFor(page.refs)
    if page.templateFile in scan.tmplRefs:
      files.incl("templates/" & page.templateFile)
      files.incl(filesFor(scan.tmplRefs[page.templateFile]))
    for f in files:
      result.mgetOrPut(f, initHashSet[string]()).incl(page.path)

proc feedDirOf(srcPage: string): string =
  ## The src feed directory an .md page belongs to ("" when none): pages
  ## directly inside a dir whose index.md declares `type: feed`, including
  ## that index.md itself.
  if not srcPage.endsWith(".md"):
    return ""
  let dir = srcPage.parentDir
  let indexFile = dir / "index.md"
  if fileExists(indexFile) and
      looseFrontmatter(indexFile).getOrDefault("type", "") == "feed":
    return dir
  return ""

proc warnUnused() =
  ## Warn about templates, components, and exec scripts no page reaches: a
  ## template no page resolves to, or a component/script not referenced by any
  ## page, used template, or transitively used component.
  let scan = scanSite()
  var usedComps = initHashSet[string]()
  var usedTmpls = initHashSet[string]()
  var usedScripts = initHashSet[string]()

  proc markRefs(refs: TagRefs) =
    for sc in refs.scripts:
      usedScripts.incl(sc)
    for c in refs.comps:
      if not usedComps.containsOrIncl(c):
        markRefs(scan.compRefs[c])

  for page in scan.pages:
    markRefs(page.refs)
    if page.templateFile in scan.tmplRefs:
      usedTmpls.incl(page.templateFile)
      markRefs(scan.tmplRefs[page.templateFile])

  for c in scan.compNames.sorted():
    if c notin usedComps:
      warn &"Warning: unused component: {scan.compPaths[c]}"
  for t in scan.templateNames.sorted():
    if t notin usedTmpls:
      warn &"Warning: unused template: templates/{t}"
  for sc in scan.scriptNames.sorted():
    if sc notin usedScripts:
      warn &"Warning: unused exec script: components/{sc}"

proc main(doReload: bool) =
  try:
    removeDir("public")
  except Exception:
    discard
  try:
    copyDir("src", "public")
  except Exception:
    error "Expected a src directory"

  # Load templates and components into cache at startup
  loadTemplates()
  loadComponents()
  warnUnused()

  let table2 = parsetoml.parseFile("hunim.toml")

  siteBaseUrl = $table2["baseURL"]
  if not siteBaseUrl.endsWith("/"):
    error "baseURL must end with /"
  siteLang = $table2["languageCode"]
  let baseUrl = siteBaseUrl
  let lang = siteLang

  # Optional [markdown] table. Absent keys fall back to the defaults above.
  keepMarkdown = table2{"markdown", "keepSource"}.getBool(false)
  mdStripFrontmatter = table2{"markdown", "stripFrontmatter"}.getBool(true)
  mdExpandTags = table2{"markdown", "expandTags"}.getBool(true)

  # Optional [highlight] table. On unless explicitly disabled.
  highlightCode = table2{"highlight", "enabled"}.getBool(true)

  var sitemapUrls: seq[string] = @[]
  feedRegistry.clear()
  feedPostLists.clear()
  execCache.clear()

  proc collectJobs(dir: string, isFeed: bool, jobs: var seq[ConvertJob]) =
    ## Recursively collect all markdown conversion jobs
    for kind, path in walkDir(dir):
      let path = toUnixPath(path)
      if kind == pcFile and path.endsWith(".md"):
        # Check if the file is a draft and should be skipped
        if not buildDrafts:
          let frontmatter = parseFrontmatter(path)
          if frontmatter.getOrDefault("draft", "false") == "true":
            continue

        let feedDir = (if isFeed and not path.endsWith(
            "index.md"): dir else: "")
        jobs.add(ConvertJob(
          doReload: doReload,
          baseUrl: baseUrl,
          lang: lang,
          file: path,
          path: path.changeFileExt("html"),
          feedDir: feedDir
        ))
      elif kind == pcDir:
        let indexFile = path / "index.md"
        var isFeed2 = false
        if fileExists(indexFile):
          let frontmatter = parseFrontmatter(indexFile)
          if frontmatter.hasKey("type") and frontmatter["type"] == "feed":
            isFeed2 = true
            # Collect posts once; reused by both the RSS feed and the post list.
            let posts = collectPosts(baseUrl, path)
            generateRSSFeed(frontmatter, lang, baseUrl,
                toUnixPath(path / "index.xml"), posts)
            feedRegistry[path] = frontmatter.getOrDefault("title", "RSS Feed")
            feedPostLists[path] = generatePostList(baseUrl, posts)
        collectJobs(path, isFeed2, jobs)

  var jobs: seq[ConvertJob] = @[]
  collectJobs("public", false, jobs)

  if jobs.len == 0:
    echo "No markdown files to convert"
  else:
    echo &"Converting {jobs.len} markdown files in parallel..."

    # Expand {{ exec }} tags on each Markdown body up front, single-threaded, so
    # a script that emits Markdown is converted as part of the page rather than
    # injected as raw text into the already-rendered HTML. Kept out of the
    # parallel workers because exec mutates the shared execCache.
    for i in 0 ..< jobs.len:
      jobs[i].body = expandExecInMarkdown(nonFrontmatter(jobs[i].file))

    # Convert every body to HTML across a small pool of worker threads. Each
    # worker pulls the next job index off a shared atomic cursor (keeping load
    # balanced) and writes into its own results slot, so no locking is needed.
    var results = newSeq[string](jobs.len)
    var next: Atomic[int]  # zero-initialized
    var ctx = ConvertCtx(jobs: addr jobs, results: addr results, next: addr next)

    let nThreads = max(1, min(countProcessors(), jobs.len))
    var threads = newSeq[Thread[ConvertCtx]](nThreads)
    for i in 0 ..< nThreads:
      createThread(threads[i], convertMarkdownWorker, ctx)
    for i in 0 ..< nThreads:
      joinThread(threads[i])

    # Collect results in job order (matching the previous sitemap ordering).
    for i in 0 ..< jobs.len:
      let url = processConvertedMarkdown(jobs[i], results[i])
      if url != "":
        sitemapUrls.add(url)


  processDirectory("public", baseUrl, sitemapUrls, doReload, lang) # Handle components
  writeSitemap(sitemapUrls, "public/sitemap.xml") # Generate sitemap
  echo "done building"


proc newSite(siteName: string) =
  createDir(siteName)
  setCurrentDir(siteName)

  writeFile(
    "hunim.toml",
    &"baseURL = 'https://{siteName}.com/'\nlanguageCode = 'en-us'\ntitle = '{siteName}'\n"
  )

  createDir("components")
  createDir("templates")
  createDir("src")
  setCurrentDir("src")
  writeFile(
    "index.html",
    &"""
<!DOCTYPE html>
<html lang="{{ .Lang }}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{siteName}</title>
</head>
<body>
  <h1>Hello World!</h1>
</body>
</html>
""",
  )

var mimeDb = newMimetypes()
mimeDb.register("md", "text/markdown")
mimeDb.register("avif", "image/avif")

proc getMimeType(filename: string): string =
  let ext = splitFile(filename).ext.toLowerAscii()
  if ext == "":
    # Extensionless clean-URL page: sniff for HTML, otherwise treat as binary.
    if fileExists(filename):
      try:
        # Read only the prefix needed to sniff for HTML, not the whole file.
        var f = open(filename, fmRead)
        defer: f.close()
        var buf = newString(15)
        let n = f.readBuffer(addr buf[0], buf.len)
        buf.setLen(n)
        let contentPrefix = buf.toLowerAscii()
        if contentPrefix.startsWith("<!doctype html") or contentPrefix.startsWith("<html"):
          return "text/html; charset=utf-8"
      except CatchableError:
        discard
    return "application/octet-stream"

  # mimeDb is populated once at startup and only read here; the dev server is
  # single-threaded, so reading it from the async handler is gc-safe.
  {.cast(gcsafe).}:
    result = mimeDb.getMimetype(ext[1 .. ^1], "application/octet-stream")
  if result.startsWith("text/") or result in ["application/json", "application/xml"]:
    result &= "; charset=utf-8"

proc serveFile(path: string): tuple[code: HttpCode, content: string,
    mimeType: string] =
  if not fileExists(path):
    return (Http404, "404 Not Found", "text/plain")

  try:
    let content = readFile(path)
    let mimeType = getMimeType(path)
    return (Http200, content, mimeType)
  except IOError:
    return (Http500, "500 Internal Server Error", "text/plain")

# --- `hunim dag` -------------------------------------------------------------
# Serves a page that draws the scanned site model as a DAG diagram:
# pages -> templates -> components -> exec scripts.

proc buildDagJson(siteTitle: string): string =
  let scan = scanSite()

  var nodes = newJArray()
  var edges = newJArray()
  var nodeSeen = initTable[string, bool]()
  var edgeSeen = initTable[string, bool]()

  proc addNode(id, label, kind: string, file = "", missing = false) =
    if nodeSeen.hasKeyOrPut(id, true):
      return
    var n = %*{"id": id, "label": label, "kind": kind}
    if file != "":
      n["file"] = %file
    if missing:
      n["missing"] = %true
    nodes.add(n)

  proc addEdge(src, dst: string) =
    if edgeSeen.hasKeyOrPut(src & " -> " & dst, true):
      return
    edges.add(%*{"from": src, "to": dst})

  proc addRefEdges(srcId: string, refs: TagRefs) =
    for c in refs.comps:
      addEdge(srcId, "c:" & c)
    for sc in refs.scripts:
      addNode("s:" & sc, sc, "script", file = "components/" & sc,
          missing = sc notin scan.scriptNames)
      addEdge(srcId, "s:" & sc)

  for t in scan.templateNames:
    addNode("t:" & t, t, "template", file = "templates/" & t)
    addRefEdges("t:" & t, scan.tmplRefs[t])

  for c in scan.compNames:
    addNode("c:" & c, scan.compPaths[c].extractFilename(), "component",
        file = scan.compPaths[c])
    addRefEdges("c:" & c, scan.compRefs[c])

  for sc in scan.scriptNames:
    addNode("s:" & sc, sc, "script", file = "components/" & sc)

  for page in scan.pages:
    let rel = page.path[4 .. ^1] # strip the leading "src/"
    let id = "p:" & rel
    addNode(id, rel, "page", file = page.path)
    addRefEdges(id, page.refs)
    if page.templateFile != "":
      addNode("t:" & page.templateFile, page.templateFile, "template",
          file = "templates/" & page.templateFile,
          missing = page.templateFile notin scan.templateNames)
      addEdge(id, "t:" & page.templateFile)

  return $(%*{"title": siteTitle, "nodes": nodes, "edges": edges})

proc dagServer() =
  let port = 8081
  let address = "127.0.0.1"

  # Read the site title up front: parsetoml isn't GC-safe, so it can't be
  # called from the async request handler.
  var siteTitle = ""
  try:
    siteTitle = parsetoml.parseFile("hunim.toml").getOrDefault("title").getStr("")
  except CatchableError:
    discard

  var httpServer = newAsyncHttpServer()

  proc handleRequest(req: Request) {.async.} =
    if req.url.path in ["", "/", "/index.html"]:
      # Rebuild the graph on every request, so refreshing the browser reflects
      # the current state of src/, templates/, and components/.
      let page = dagPage(buildDagJson(siteTitle))
      await req.respond(Http200, page,
          newHttpHeaders([("Content-Type", "text/html; charset=utf-8")]))
    else:
      await req.respond(Http404, "404 Not Found",
          newHttpHeaders([("Content-Type", "text/plain")]))

  stdout.styledWriteLine(fgGreen, &"DAG viewer running at http://{address}:{port}/")
  stdout.styledWriteLine(fgYellow, "Press Ctrl+C to stop")
  stdout.resetAttributes()

  waitFor httpServer.serve(Port(port), handleRequest, address)

proc rebuild(doReload: bool) =
  stdout.styledWriteLine(fgCyan, "Rebuilding site...")
  stdout.resetAttributes()
  try:
    main(doReload)
  except:
    stderr.styledWriteLine(fgRed, "Build failed: " & getCurrentExceptionMsg())
    stderr.resetAttributes()

# --- Smart rebuilds for `hunim server` ----------------------------------------
# Instead of rebuilding the whole site on any change under src/, the watcher
# snapshots every build input (hunim.toml, src/, templates/, components/) and
# rebuilds only what a change actually affects: a page rebuilds itself, a
# template/component/script rebuilds the pages that transitively use it (via
# reverseDeps), and a static asset is just re-copied. Additions, removals, and
# hunim.toml changes restructure the site (routes, feed membership, the
# dependency graph itself), so those take the full-rebuild path. Partial
# rebuilds leave sitemap.xml untouched; it refreshes on the next full rebuild.

proc snapshotInputs(): Table[string, Time] =
  ## Modification times of every build input.
  if fileExists("hunim.toml"):
    result["hunim.toml"] = getFileInfo("hunim.toml").lastWriteTime

  proc walk(dir: string, snap: var Table[string, Time]) =
    for kind, path in walkDir(dir):
      if kind == pcFile:
        snap[toUnixPath(path)] = getFileInfo(path).lastWriteTime
      elif kind == pcDir:
        walk(path, snap)

  for dir in ["src", "templates", "components"]:
    if dirExists(dir):
      walk(dir, result)

proc convertSingle(job: ConvertJob) =
  ## Convert one Markdown job synchronously and finish its page (template,
  ## components, clean URL). Partial rebuilds touch a handful of pages, so no
  ## thread pool is needed.
  let html = markdown(job.body)
  discard processConvertedMarkdown(job,
      if highlightCode: highlightCodeBlocks(html) else: html)
  discard processFile(job.path, job.baseUrl, job.doReload, job.lang)

proc removeStaleOutputs(pubMd: string) =
  ## Drop the pages a previous build may have generated for a now-draft .md
  ## source. (Like the full build, the source copy itself stays in public/.)
  removeFile(pubMd.changeFileExt("html"))
  removeFile(pubMd.changeFileExt(""))

proc rebuildSrcPage(srcPath: string) =
  ## Rebuild a single non-feed page from its src file, mirroring what the full
  ## build produces for it.
  let pubPath = "public" & srcPath[3 .. ^1]
  createDir(pubPath.parentDir)
  copyFile(srcPath, pubPath)
  if pubPath.endsWith(".md"):
    if not buildDrafts and
        looseFrontmatter(pubPath).getOrDefault("draft", "false") == "true":
      removeStaleOutputs(pubPath)
      return
    var job = ConvertJob(doReload: true, baseUrl: siteBaseUrl, lang: siteLang,
        file: pubPath, path: pubPath.changeFileExt("html"), feedDir: "")
    job.body = expandExecInMarkdown(nonFrontmatter(pubPath))
    convertSingle(job)
  else:
    discard processFile(pubPath, siteBaseUrl, true, siteLang)

proc rebuildFeedDir(srcDir: string) =
  ## Rebuild a feed directory wholesale: a change to any post also changes the
  ## feed's RSS and the index page's post list, so redo the whole directory.
  let pubDir = "public" & srcDir[3 .. ^1]
  createDir(pubDir)
  var mdFiles: seq[string] = @[]
  for f in walkFiles(srcDir / "*.md"):
    let f = toUnixPath(f)
    let dest = toUnixPath(pubDir / f.extractFilename())
    copyFile(f, dest)
    mdFiles.add(dest)

  let frontmatter = looseFrontmatter(pubDir / "index.md")
  let posts = collectPosts(siteBaseUrl, pubDir)
  generateRSSFeed(frontmatter, siteLang, siteBaseUrl,
      toUnixPath(pubDir / "index.xml"), posts)
  feedRegistry[pubDir] = frontmatter.getOrDefault("title", "RSS Feed")
  feedPostLists[pubDir] = generatePostList(siteBaseUrl, posts)

  for f in mdFiles:
    if not buildDrafts and
        looseFrontmatter(f).getOrDefault("draft", "false") == "true":
      removeStaleOutputs(f)
      continue
    var job = ConvertJob(doReload: true, baseUrl: siteBaseUrl, lang: siteLang,
        file: f, path: f.changeFileExt("html"),
        feedDir: (if f.endsWith("index.md"): "" else: pubDir))
    job.body = expandExecInMarkdown(nonFrontmatter(f))
    convertSingle(job)

proc smartRebuild(added, removed, modified: seq[string]) =
  if added.len > 0 or removed.len > 0 or "hunim.toml" in modified:
    rebuild(doReload = true)
    return

  var pages = initHashSet[string]()
  var assets: seq[string] = @[]
  var depFiles: seq[string] = @[]
  for f in modified:
    if f.startsWith("src/"):
      if f.splitFile().ext.toLowerAscii() in [".md", ".html"]:
        pages.incl(f)
      else:
        assets.add(f)
    else:
      depFiles.add(f)

  if depFiles.len > 0:
    let rev = reverseDeps(scanSite())
    for f in depFiles:
      # A changed script's cached output is stale; drop it so its dependents
      # re-run it.
      if f.endsWith(".nims"):
        execCache.del(f.extractFilename())
      for p in rev.getOrDefault(f):
        pages.incl(p)

  try:
    for a in assets:
      let dest = "public" & a[3 .. ^1]
      createDir(dest.parentDir)
      copyFile(a, dest)
    if assets.len > 0:
      stdout.styledWriteLine(fgCyan, &"Copied {assets.len} static file(s)")
      stdout.resetAttributes()

    if pages.len == 0:
      return

    var feedDirs = initHashSet[string]()
    var singles: seq[string] = @[]
    for p in pages:
      let fd = feedDirOf(p)
      if fd != "":
        feedDirs.incl(fd)
      else:
        singles.add(p)

    var what = &"{singles.len} page(s)"
    if feedDirs.len > 0:
      what &= &" and {feedDirs.len} feed(s)"
    stdout.styledWriteLine(fgCyan, &"Rebuilding {what}...")
    stdout.resetAttributes()

    loadTemplates()
    loadComponents()
    for d in feedDirs:
      rebuildFeedDir(d)
    for p in singles:
      rebuildSrcPage(p)
  except CatchableError:
    stderr.styledWriteLine(fgRed, "Rebuild failed: " & getCurrentExceptionMsg())
    stderr.resetAttributes()

proc server() =
  let port = 8080
  let address = "127.0.0.1"

  var httpServer = newAsyncHttpServer()
  var snapshot = snapshotInputs()

  proc handleRequest(req: Request) {.async.} =
    var path = req.url.path.decodeUrl()

    # Normalize path
    if path == "" or path == "/":
      path = "/index.html"

    # Build full file path
    let filePath = "public" & path

    # Security: confine served files to the public root. Normalizing collapses
    # any ".." segments, so we reject anything that escapes the root rather than
    # blindly blocking the "" substring (which would also reject valid names).
    let publicRoot = absolutePath("public")
    let resolved = absolutePath(normalizedPath(filePath))
    if resolved != publicRoot and not resolved.isRelativeTo(publicRoot):
      await req.respond(Http403, "403 Forbidden")
      return

    proc addCrossOriginHeaders(headers: var HttpHeaders) =
      headers["Cross-Origin-Opener-Policy"] = "same-origin"
      headers["Cross-Origin-Embedder-Policy"] = "require-corp"

    # If path is a directory, try to serve index.html
    if dirExists(filePath):
      let indexPath = filePath / "index.html"
      let (code, content, mimeType) = serveFile(indexPath)
      var headers = newHttpHeaders([("Content-Type", mimeType)])
      addCrossOriginHeaders(headers)
      await req.respond(code, content, headers)
    else:
      let (code, content, mimeType) = serveFile(filePath)
      var headers = newHttpHeaders([("Content-Type", mimeType)])
      addCrossOriginHeaders(headers)
      await req.respond(code, content, headers)

    # echo &"{req.reqMethod} {req.url.path} -> {filePath}"

  proc checkForChanges {.async.} =
    while true:
      await sleepAsync(100) # 0.1sec
      let current = snapshotInputs()
      if current == snapshot:
        continue
      var added, removed, modified: seq[string]
      for path, mtime in current:
        if path notin snapshot:
          added.add(path)
        elif snapshot[path] != mtime:
          modified.add(path)
      for path in snapshot.keys:
        if path notin current:
          removed.add(path)
      snapshot = current
      smartRebuild(added, removed, modified)

  stdout.styledWriteLine(fgGreen, &"Server running at http://{address}:{port}/")
  stdout.styledWriteLine(fgYellow, "Press Ctrl+C to stop")
  stdout.resetAttributes()

  asyncCheck checkForChanges()

  waitFor httpServer.serve(Port(port), handleRequest, address)

when isMainModule:
  var cmd = ""
  var cmd2 = ""

  for i in 1..paramCount():
    if paramStr(i) == "--buildDrafts" or paramStr(i) == "-D":
      buildDrafts = true
    elif not paramStr(i).startsWith("-") and cmd == "":
      cmd = paramStr(i)
    elif cmd2 == "":
      cmd2 = paramStr(i)

  if cmd == "" or cmd == "build":
    main(doReload=false)
  elif cmd == "version":
    echo version
  elif cmd == "newsite":
    if cmd2 == "":
      error "You must provide a site name"
    newSite(cmd2)
  elif cmd == "server":
    rebuild(doReload=true)
    server()
  elif cmd == "dag":
    dagServer()
  else:
    error &"Unknown command: {cmd}"
