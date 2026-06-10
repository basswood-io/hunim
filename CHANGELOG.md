# 0.3.1

## Fixes
 - Component arguments in Markdown pages are now parsed correctly; previously the quotes were HTML-escaped during Markdown conversion, breaking argument splitting so only `$1` was substituted (#5)
 - `{{ … }}` tags shown inside code samples (`<pre>`/`<code>`) are no longer expanded, so documentation can display literal template, component, and exec tags without HTML-entity workarounds. As part of this, `{{ exec … }}` now runs after Markdown conversion (its output is inserted as-is rather than re-processed as Markdown)

