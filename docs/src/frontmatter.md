---
title: Frontmatter
desc: Add metadata to Markdown pages using YAML-style frontmatter.
---

# Frontmatter

Frontmatter is a block of metadata at the top of a Markdown file, delimited by `---` lines. Hunim reads this metadata to set the page title, choose a template, generate meta tags, and control build behavior.

## Syntax

```markdown
---
title: My Page Title
author: Jane Doe
date: Mon, 19 Nov 2024 12:00:00 PST
desc: A short description of this page.
template: custom.html
draft: false
type: feed
---

# Page content starts here
```

## Fields

| Field | Description |
|-------|-------------|
| `title` | Page title. Used as `{{ .Title }}` in templates and in `<title>` and `og:title` meta tags. If omitted, a title is derived from the filename (see [Omitting frontmatter](#omitting-frontmatter)). |
| `author` | Author name. Available as `{{ .Author }}` in templates. |
| `date` | Publication date in [RFC 2822](https://www.rfc-editor.org/rfc/rfc2822) format. Available as `{{ .Date }}` (formatted as `Month DD, YYYY`). |
| `desc` | Short description. Injected as a `<meta name="description">` and `og:description` tag via `{{ .MetaTags }}`. Use the special value `no-index` to prevent the page from appearing in the sitemap. |
| `template` | Name of the template file to use (e.g. `wide.html`). Defaults to `default.html`. |
| `draft` | Set to `true` to exclude the page from normal builds. Included when using `--buildDrafts`. |
| `type` | Set to `feed` on a directory's `index.md` to enable the blog feed system. See [Feeds](/feeds). |

## Date format

Dates follow [RFC 2822](https://www.rfc-editor.org/rfc/rfc2822). Common timezone abbreviations are supported:

```
Mon, 19 Nov 2024 12:00:00 PST
Tue, 01 Jan 2025 09:00:00 UTC
Wed, 05 Mar 2025 18:30:00 EDT
```

The date is rendered in the template as a human-readable string, e.g. `November 19, 2024`.

## The `no-index` descriptor

Set `desc: no-index` to exclude a page from the generated `sitemap.xml` and add a `<meta name="robots" content="noindex">` tag:

```markdown
---
title: Draft Preview
desc: no-index
---
```

## Omitting frontmatter

Frontmatter is optional. A Markdown file without frontmatter is still processed: `{{ .Content }}` holds the rendered Markdown. When there is no `title`, the title is derived from the filename — hyphens become spaces and each word is capitalized, so `my-cool-post.md` becomes `My Cool Post`. This title is used for both `{{ .Title }}` and the `og:title` meta tag. A `desc` is still required to emit a description / `og:description` tag.
