# 0.4.0

## Features
 - Added an optional `[markdown]` table to `hunim.toml`. With `keepSource = true`, each page's Markdown source is published next to its HTML at the same route with a `.md` extension (e.g. `/getting-started.md`), instead of being deleted after conversion — handy for serving a plain-text / LLM-readable copy of every page. `stripFrontmatter` (default true) drops the `---` block, and `expandTags` (default true) runs the component, `{{ .Var }}`, and `{{ exec }}` passes over the body while leaving tags inside code samples (fenced, inline, and `<pre>`/`<code>`) literal

# 0.3.1

## Fixes
 - Component arguments in Markdown pages are now parsed correctly; previously the quotes were HTML-escaped during Markdown conversion, breaking argument splitting so only `$1` was substituted (#5)
 - `{{ … }}` tags shown inside code samples (`<pre>`/`<code>`) are no longer expanded, so documentation can display literal template, component, and exec tags without HTML-entity workarounds. As part of this, `{{ exec … }}` now runs after Markdown conversion (its output is inserted as-is rather than re-processed as Markdown)

