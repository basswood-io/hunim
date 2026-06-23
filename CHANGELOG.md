# 0.4.0

## Features
 - Added an optional `[markdown]` table to `hunim.toml`. With `keepSource = true`, each page's Markdown source is published next to its HTML at the same route with a `.md` extension (e.g. `/getting-started.md`), instead of being deleted after conversion — handy for serving a plain-text / LLM-readable copy of every page. `stripFrontmatter` (default true) drops the `---` block, and `expandTags` (default true) runs the component, `{{ .Var }}`, and `{{ exec }}` passes over the body while leaving tags inside code samples (fenced, inline, and `<pre>`/`<code>`) literal

## Fixes
 - In Markdown pages, `{{ exec … }}` now expands before Markdown conversion, so a script that emits Markdown (headings, tables, emphasis) is rendered as part of the page instead of being injected as raw text into the already-converted HTML. Tags inside code samples (fenced, inline, and `<pre>`/`<code>`) are still left literal
