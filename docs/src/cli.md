---
title: CLI Reference
desc: All Hunim commands and flags.
---

# CLI Reference

## Commands

### `hunim` / `hunim build`

Build the site. Reads from `src/`, writes to `public/`. `hunim build` is an explicit alias for the bare `hunim` command.

```
hunim [build] [--buildDrafts]
```

| Flag | Description |
|------|-------------|
| `--buildDrafts` | Include pages with `draft: true` in the build. |

Building warns on stderr about unused files: templates, components, and exec scripts that no page reaches, directly or through its template and components.

---

### `hunim server`

Start the development server with hot reload.

```
hunim server [--buildDrafts]
```

- Serves the built site at `http://127.0.0.1:8080`.
- Watches `src/`, `templates/`, `components/`, and `hunim.toml`, and rebuilds only what a change affects:
  - An edited page rebuilds just that page.
  - An edited template, component, or exec script rebuilds the pages that (transitively) use it — nothing else.
  - An edited static asset (CSS, images, …) is re-copied without rebuilding any page.
  - A change to any page in a feed directory rebuilds that feed (its posts, post list, and RSS).
  - Adding or deleting files, or editing `hunim.toml`, triggers a full rebuild. `sitemap.xml` is only refreshed on full rebuilds.
- Injects an auto-reload script into every page (polls every 100 ms); production builds contain no such script.
- Press `Ctrl+C` to stop.

| Flag | Description |
|------|-------------|
| `--buildDrafts` | Include draft pages in the server build. |

---

### `hunim dag`

Serve an interactive diagram of the site's structure as a DAG.

```
hunim dag
```

- Serves at `http://127.0.0.1:8081` (a different port than `hunim server`, so both can run at once).
- Draws every page, template, component, and exec script as a node, with edges for the `template` frontmatter key (including implicit feed templates), component invocations, and exec tags.
- Hover a node to trace everything it depends on and everything that uses it; click to pin the highlight.
- A template that is referenced but doesn't exist in `templates/` is flagged as missing.
- Tags inside code samples are ignored, matching the build.
- Refresh the browser to rescan the site; no build required.

---

### `hunim newsite`

Scaffold a new site directory.

```
hunim newsite <name>
```

Creates a directory called `<name>` containing:

```
<name>/
├── hunim.toml
├── src/
│   └── index.html
├── templates/
└── components/
```

---

### `hunim version`

Print the installed version number and exit.

```
hunim version
```

## Build output

All commands write to the `public/` directory:

| File | Description |
|------|-------------|
| `public/**/*.html` | Converted Markdown and copied HTML files |
| `public/sitemap.xml` | Sitemap with all indexed pages |
| `public/{feed}/index.xml` | RSS feed for each feed directory |

## URL structure

Markdown files are converted and their paths are cleaned:

| Source | Output URL |
|--------|-----------|
| `src/index.md` | `/` |
| `src/about.md` | `/about` |
| `src/index.md` | `/` |
| `src/templates.md` | `/templates` |

Static assets (images, CSS, JS) are copied as-is without modification.
