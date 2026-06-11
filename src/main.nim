import std/[algorithm, sequtils, strformat, strutils, terminal, times, os,
    osproc, tables, threadpool]
import std/[asynchttpserver, asyncdispatch, uri]

import ./[about, md4c_wrapper]

import parsetoml


# Global caches for templates and components
var templateCache = initTable[string, string]()
var componentCache = initTable[string, string]()
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

proc loadComponents() =
  ## Load all components from the components directory into cache
  componentCache.clear()
  if not dirExists("components"):
    return

  for kind, comp in walkDir("components"):
    let compName = comp.extractFilename().changeFileExt("")
    if kind == pcFile and not compName.startsWith("."):
      componentCache[compName] = readFile(comp).strip()

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

func shouldProcessFile(path: string): bool =
  if path.endsWith(".DS_Store"):
    return false

  let ext = path.splitFile().ext.toLowerAscii()
  return ext notin [".avif", ".webp", ".png", ".jpeg", ".jpg", ".svg"]

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

    let scriptPath = "components" / scriptName

    if not fileExists(scriptPath):
      error &"NimScript not found: {scriptPath}"

    let (output, exitCode) = execCmdEx("nim e --hints:off " & scriptPath)
    if exitCode != 0:
      error &"NimScript failed ({scriptName}):\n{output}"

    let fullMatch = newContent[openIdx .. closeIdx + 2]
    let trimmed = output.strip()
    newContent = newContent.replace(fullMatch, trimmed)
    startIdx = openIdx + trimmed.len

  return newContent

proc processExecTags(content: string): string =
  ## Replace {{ exec script.nims }} tags with the script's stdout, skipping any
  ## inside <pre>/<code> so documented tags stay literal.
  for seg in codeSegments(content):
    result &= (if seg.isCode: seg.text else: processExecTagsSegment(seg.text))

proc processFile(path: string, baseUrl: string, doReload: bool, lang: string): string =
  # Skip non-HTML files
  let ext = path.splitFile().ext.toLowerAscii()
  if ext != ".html":
    return ""

  if not shouldProcessFile(path):
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
    if kind == pcFile:
      let url = processFile(path, baseUrl, doReload, lang)
      if url != "":
        urls.add(url)
    elif kind == pcDir:
      processDirectory(path, baseUrl, urls, doReload, lang)

type

  TokenKind = enum
    tkBar,
    keyval,
    tkText,
    tkNewline,
    tkEOF,

  Token = ref object
    kind: TokenKind
    value: string

  State = enum
    startState,
    headState,
    finalState,

  Lexer = ref object
    name: string
    text: string
    currentChar: char
    state: State
    pos: int
    line: int
    col: int

type BlogPost = object
  title: string
  link: string
  desc: string
  path: string      # For sorting by date
  pubDate: string
  dateObj: DateTime # For sorting

func initLexer(name, text: string): Lexer =
  Lexer(name: name, text: text,
      currentChar: (if text.len > 0: text[0] else: '\0'),
      state: startState, line: 1, col: 1)

proc error(self: Lexer, msg: string) =
  stderr.writeLine(&"{self.name}:{self.line}:{self.col} {msg}")
  system.quit(1)

proc advance(self: Lexer) =
  self.pos += 1
  if self.pos > len(self.text) - 1:
    self.currentChar = '\0'
  else:
    if self.currentChar == '\n':
      self.line += 1
      self.col = 1
    else:
      self.col += 1

    self.currentChar = self.text[self.pos]

func peek(self: Lexer): char =
  let peakPos = self.pos + 1
  return (if peakPos > len(self.text) - 1: '\0' else: self.text[peakPos])

func initToken(kind: TokenKind, value: string): Token =
  return Token(kind: kind, value: value)

proc getNextToken(self: Lexer): Token =
  var rod = ""
  while self.currentChar != '\0':
    if self.currentChar == '\n':
      self.advance()
      return initToken(tkNewline, "")

    rod &= self.currentChar

    if self.state == headState and self.currentChar == ':':
      self.advance() # then go to ` `
      while self.currentChar == ' ':
        self.advance()

      rod = ""
      while self.currentChar != '\n':
        if self.currentChar == '\0':
          self.error("Got EOF on key-value pair")

        if self.currentChar != '\n':
          rod &= self.currentChar

        self.advance()

      self.advance()
      return initToken(keyval, rod)

    if rod == "---":
      self.advance()
      self.advance()
      if self.state == startState:
        self.state = headState
      elif self.state == headState:
        self.state = finalState
      return initToken(tkBar, "")

    if self.peek() == '\n' or (self.state == headState and self.peek() == ':'):
      self.advance()
      if rod.strip() == "":
        continue
      else:
        return initToken(tkText, rod)

    self.advance()

  return initToken(tkEOF, "")

proc parseFrontmatter(file: string): Table[string, string] =
  let text = readFile(file)
  var lexer = initLexer(file, text)

  # Frontmatter is optional; a file without a leading `---` has no metadata.
  if getNextToken(lexer).kind != tkBar:
    return

  var token = getNextToken(lexer)
  while token.kind != tkBar:
    if token.kind == tkText:
      let key = token.value
      token = getNextToken(lexer)
      if token.kind != keyval:
        lexer.error("frontmatter: Expected key value pair")
      result[key] = token.value
      token = getNextToken(lexer)
    elif token.kind != tkBar:
      lexer.error("frontmatter: Expected --- at the end")

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
  let text = readFile(file)
  var lexer = initLexer(file, text)

  # Frontmatter is optional; without a leading `---` the whole file is content.
  if getNextToken(lexer).kind != tkBar:
    return text

  var token = getNextToken(lexer)
  while token.kind != tkBar:
    if token.kind == tkText:
      token = getNextToken(lexer)
      if token.kind != keyval:
        lexer.error("frontmatter: Expected key value pair")
      token = getNextToken(lexer)
    elif token.kind != tkBar:
      lexer.error("frontmatter: Expected --- at the end")

  return text[lexer.pos..^1]

proc xmlEscape(text: string): string =
  ## Escape characters that are special in XML/HTML.
  text.replace("&", "&amp;")
      .replace("<", "&lt;")
      .replace(">", "&gt;")
      .replace("\"", "&quot;")
      .replace("'", "&#39;")

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
  let title = xmlEscape(frontmatter.getOrDefault("title", "RSS Feed"))
  let desc = xmlEscape(frontmatter.getOrDefault("desc", "My RSS Feed"))
  let link = xmlEscape(baseUrl)

  # The feed's own canonical URL, advertised via <atom:link rel="self">.
  let selfUrl = xmlEscape(baseUrl & outputPath.replace("public/", ""))

  # Generate RSS XML
  var rssContent = &"""<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:atom="http://www.w3.org/2005/Atom" version="2.0">
  <channel>
    <title>{title}</title>
    <link>{link}</link>
    <atom:link href="{selfUrl}" rel="self" type="application/rss+xml"/>
    <description>{desc}</description>
    <language>{xmlEscape(lang)}</language>
"""

  # Add items
  for post in posts:
    let summary =
      if post.desc != "": post.desc & " "
      else: ""
    let description = xmlEscape(
      &"""{summary}<div style="margin-top: 50px; font-style: italic;"><strong><a href="{post.link}">Keep reading</a>.</strong></div>""")
    let itemTitle = xmlEscape(post.title)
    let itemLink = xmlEscape(post.link)
    let pubDate = xmlEscape(post.pubDate)
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

type ConvertResult = object
  job: ConvertJob
  htmlOutput: string

proc convertMarkdownWorker(job: ConvertJob): ConvertResult =
  ## Worker function that converts markdown to HTML. Exec tags are expanded
  ## later (in processConvertedMarkdown, after the template is applied) so that,
  ## like component and variable tags, they are never run inside a code sample —
  ## whether written as a Markdown fence or a raw HTML block.
  let htmlOutput = markdown(nonFrontmatter(job.file))
  return ConvertResult(job: job, htmlOutput: htmlOutput)

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
    metaTags &= &"\n  <meta property=\"og:title\" content=\"{xmlEscape(pageTitle)}\">"

  if desc != "" and desc != "no-index":
    metaTags &= &"\n  <meta name=\"description\" content=\"{xmlEscape(desc)}\">"

  var sitemapUrl = ""
  if desc != "no-index":
    var url = job.path.replace("public/", "")
    if url.endswith("/index.html"):
      url = url.replace("/index.html", "")
    else:
      url = url.replace(".html", "")
    let canonical = xmlEscape(job.baseUrl & url)
    metaTags &= &"\n  <link rel=\"canonical\" href=\"{canonical}\">"
    metaTags &= &"\n  <meta property=\"og:url\" content=\"{canonical}\">"
    sitemapUrl = job.baseUrl & url

    var feedDir = job.feedDir
    if feedDir == "" and feedRegistry.hasKey(job.path.parentDir):
      feedDir = job.path.parentDir
    if feedRegistry.hasKey(feedDir):
      let feedTitle = xmlEscape(feedRegistry[feedDir])
      let feedHref = xmlEscape(job.baseUrl & feedDir.replace("public/", "") & "/index.xml")
      metaTags &= &"\n  <link rel=\"alternate\" type=\"application/rss+xml\" title=\"{feedTitle}\" href=\"{feedHref}\">"
  else:
    metaTags &= "\n  <meta name=\"robots\" content=\"noindex\">"

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

  let table2 = parsetoml.parseFile("hunim.toml")

  let baseUrl = $table2["baseURL"]
  if not baseUrl.endsWith("/"):
    error "baseURL must end with /"

  let lang = $table2["languageCode"]

  # Optional [markdown] table. Absent keys fall back to the defaults above.
  keepMarkdown = table2{"markdown", "keepSource"}.getBool(false)
  mdStripFrontmatter = table2{"markdown", "stripFrontmatter"}.getBool(true)
  mdExpandTags = table2{"markdown", "expandTags"}.getBool(true)

  var sitemapUrls: seq[string] = @[]
  feedRegistry.clear()
  feedPostLists.clear()

  proc collectJobs(dir: string, isFeed: bool, jobs: var seq[ConvertJob]) =
    ## Recursively collect all markdown conversion jobs
    for kind, path in walkDir(dir):
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
            generateRSSFeed(frontmatter, lang, baseUrl, path / "index.xml", posts)
            feedRegistry[path] = frontmatter.getOrDefault("title", "RSS Feed")
            feedPostLists[path] = generatePostList(baseUrl, posts)
        collectJobs(path, isFeed2, jobs)

  var jobs: seq[ConvertJob] = @[]
  collectJobs("public", false, jobs)

  if jobs.len == 0:
    echo "No markdown files to convert"
  else:
    echo &"Converting {jobs.len} markdown files in parallel..."

    # Process all jobs in parallel
    var flowVars = newSeq[FlowVar[ConvertResult]](jobs.len)

    # Spawn all conversion tasks
    for i in 0 ..< jobs.len:
      flowVars[i] = spawn convertMarkdownWorker(jobs[i])

    # Wait for all tasks to complete and collect results
    for flowVar in flowVars:
      let result = ^flowVar
      let url = processConvertedMarkdown(result.job, result.htmlOutput)
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

proc getMimeType(filename: string): string =
  let ext = splitFile(filename).ext.toLowerAscii()
  case ext
  of ".html", ".htm":
    return "text/html; charset=utf-8"
  of ".css":
    return "text/css; charset=utf-8"
  of ".js":
    return "application/javascript; charset=utf-8"
  of ".json":
    return "application/json; charset=utf-8"
  of ".xml":
    return "application/xml; charset=utf-8"
  of ".md":
    return "text/markdown; charset=utf-8"
  of ".png":
    return "image/png"
  of ".jpg", ".jpeg":
    return "image/jpeg"
  of ".gif":
    return "image/gif"
  of ".svg":
    return "image/svg+xml"
  of ".webp":
    return "image/webp"
  of ".avif":
    return "image/avif"
  of ".wasm":
    return "application/wasm"
  of ".ttf":
    return "font/ttf"
  of ".pdf":
    return "application/pdf"
  of "":
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
  else:
    return "application/octet-stream"

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

proc getLastModTime(dir: string): Time =
  var lastMod = fromUnix(0)
  if not dirExists(dir):
    return lastMod

  for kind, path in walkDir(dir):
    if kind == pcFile:
      let info = getFileInfo(path)
      if info.lastWriteTime > lastMod:
        lastMod = info.lastWriteTime
    elif kind == pcDir:
      let subdirMod = getLastModTime(path)
      if subdirMod > lastMod:
        lastMod = subdirMod

  return lastMod

proc rebuild(doReload: bool) =
  stdout.styledWriteLine(fgCyan, "Rebuilding site...")
  stdout.resetAttributes()
  try:
    main(doReload)
  except:
    stderr.styledWriteLine(fgRed, "Build failed: " & getCurrentExceptionMsg())
    stderr.resetAttributes()

proc server() =
  let port = 8080
  let address = "127.0.0.1"

  var httpServer = newAsyncHttpServer()
  var lastModTime = getLastModTime("src")

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
      let currentModTime = getLastModTime("src")
      if currentModTime > lastModTime:
        lastModTime = currentModTime
        rebuild(true)

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
  else:
    error &"Unknown command: {cmd}"
