---
title: Configuration
desc: Configure your Hunim site with hunim.toml.
---

# Configuration

Every Hunim site has a `hunim.toml` file at the project root. This file controls site-wide settings used during the build.

## hunim.toml

```toml
baseURL      = 'https://example.com/'
languageCode = 'en-us'
title        = 'My Site'
```

All three fields are required.

## Fields

| Field | Type | Description |
|-------|------|-------------|
| `baseURL` | string | The root URL of your deployed site. **Must end with `/`**. Used for sitemap URLs and RSS feed links. |
| `languageCode` | string | An [RFC 5646](https://www.rfc-editor.org/rfc/rfc5646) language tag (e.g. `en-us`, `fr`, `de`). Exposed as `{{ .Lang }}` in templates. |
| `title` | string | The name of your site. Used in RSS feed metadata. |

## Publishing Markdown source

By default the Markdown source of a page is deleted once it has been converted to HTML. Add an optional `[markdown]` table to instead publish each page's Markdown next to its HTML, at the same route with a `.md` extension — useful for serving an LLM-readable or plain-text copy of every page.

```toml
[markdown]
keepSource       = true   # publish .md alongside .html (default false)
stripFrontmatter = true   # drop the --- frontmatter block (default true)
expandTags       = true   # expand component / {{ .Var }} / exec tags (default true)
```

With `keepSource = true`, a page at `/docs/getting-started` also becomes available at `/docs/getting-started.md` (and `index.md` pages at `/docs/index.md`).

| Field | Type | Description |
|-------|------|-------------|
| `keepSource` | bool | Publish the Markdown rendition. The whole table is ignored when this is `false`. |
| `stripFrontmatter` | bool | Remove the leading `---` frontmatter block so the `.md` starts at the page body. |
| `expandTags` | bool | Run the [component](/components), `{{ .Var }}`, and `{{ exec }}` passes over the body. Tags inside code samples — fenced ` ``` ` blocks, inline `` `spans` ``, and `<pre>`/`<code>` — are left literal, exactly as in the HTML output. Note that expanding a component substitutes its raw HTML into the Markdown. |

Drafts are never published as `.md`, and the `.md` renditions are not added to `sitemap.xml`.

## Example

```toml
baseURL      = 'https://mysite.dev/'
languageCode = 'en-us'
title        = 'My Awesome Site'
```

> The `baseURL` must end with a trailing slash, otherwise sitemap and feed URLs will be malformed.
