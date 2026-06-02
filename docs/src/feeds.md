---
title: Feeds
desc: Set up a blog with automatic RSS feed generation.
---

# Feeds

Hunim's feed system turns any directory into a blog with automatic post indexing and RSS feed generation.

## Enabling a feed

Add an `index.md` to a directory with `type: feed` in its frontmatter:

```
src/
  blog/
    index.md       ← type: feed
    first-post.md
    second-post.md
```

`src/blog/index.md`:

```markdown
---
title: My Blog
type: feed
---

Welcome to my blog!
```

Hunim will:

1. Collect all `.md` files in `blog/` (except `index.md`) as posts.
2. Sort posts by `date` descending (newest first).
3. Render each post using `templates/blog_list.html` (if it exists).
4. Generate `public/blog/index.xml` — a valid RSS feed.

## Listing posts on the index page

Instead of maintaining a list of links to your posts by hand, drop a
`{{ .PostList }}` placeholder into the feed's `index.md`. Hunim replaces it with
the sorted (newest-first) list of posts:

```markdown
---
title: My Blog
type: feed
---

Welcome to my blog!

{{ .PostList }}
```

Each post is rendered as a paragraph linking to the post, followed by its
formatted publish date:

```html
<p><a href="/blog/second-post/">Second Post</a> November 19, 2024</p>
<p><a href="/blog/hello-world/">Hello World</a> July 29, 2024</p>
```

Post titles are rendered as inline markdown, so backticks and other inline
formatting in a title carry through. Dates are formatted as `Month d, yyyy`,
matching the date shown on each post page.

## Feed template

Create a template named after the feed directory with a `_list` suffix:

| Feed directory | Template file |
|----------------|---------------|
| `src/blog/` | `templates/blog_list.html` |
| `src/news/` | `templates/news_list.html` |
| `src/articles/` | `templates/articles_list.html` |

If the template does not exist, Hunim falls back to `templates/default.html`.

## Post frontmatter

Each post should include `title`, `date`, and optionally `author` and `desc`:

```markdown
---
title: My First Post
author: Jane Doe
date: Mon, 19 Nov 2024 12:00:00 PST
desc: An introduction to my new blog.
---

# My First Post

Content goes here.
```

Posts without a `date` appear at the end of the list (after all dated posts).

## RSS feed

Hunim generates a standards-compliant RSS 2.0 feed at `{feeddir}/index.xml`. The feed uses:

- `title` — from `hunim.toml`
- `link` — from `baseURL` in `hunim.toml`
- Each item's `title`, `link`, `pubDate`, and `description` — from post frontmatter

### Feed autodiscovery

Hunim automatically advertises the feed for autodiscovery. Every page in a feed
directory (the feed index and each post) gets a `<link rel="alternate">` injected
into its `<head>`, as long as the template renders `{{ .MetaTags }}`:

```html
<link rel="alternate" type="application/rss+xml"
      title="My Blog" href="https://example.com/blog/index.xml">
```

The `title` comes from the feed's `index.md` frontmatter and the `href` points at
the generated `index.xml`. You don't need to add this tag yourself.

## Example structure

```
src/
  blog/
    index.md              # type: feed
    hello-world.md
    second-post.md

templates/
  blog_list.html          # Applied to individual posts

public/                   # Generated output
  blog/
    index.html
    index.xml             # RSS feed
    hello-world/
      index.html
    second-post/
      index.html
```
