# 0.6.3

## Fixes
 - A component no longer expands inside a longer tag that starts with its name (component `nav` no longer replaces `{{ navbar }}`)
 - A failing Markdown page no longer crashes the build; every failing page is reported by file
 - A malformed `date:` in frontmatter now gives a clear error instead of a stack trace
 - A failing `{{ exec }}` script is now reported cleanly instead of exiting from a worker thread
 - Markdown output is no longer silently truncated when memory runs out, and the md4c output buffer no longer leaks on failure
 - A failure to remove the old `public/` directory now prints a warning instead of being ignored
 - Fix a crash on Windows after pages or `{{ exec }}` scripts were rendered on worker threads
 - On Windows, a feed's index page now gets its `{{ .PostList }}` and RSS autodiscovery link
 - On Windows, HTML pages are no longer listed in `sitemap.xml` with a `public\` prefix
 - On Windows, editing a feed post under `hunim server` no longer drops the feed template and breaks the RSS link
