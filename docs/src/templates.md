---
title: Templates
weight: 30
desc: Build reusable HTML layouts for your Markdown pages.
---

# Templates

Templates are HTML files stored in the `templates/` directory. Hunim wraps Markdown content inside the matching template before writing it to `public/`.

## Default template

Create `templates/default.html` and it will be applied to every Markdown file that does not specify a custom template:

<pre><code class="language-html">&lt;!DOCTYPE html&gt;
&lt;html lang=&quot;&#123;&#123; .Lang &#125;&#125;&quot;&gt;
&lt;head&gt;
  &lt;meta charset=&quot;utf-8&quot;&gt;
  &lt;meta name=&quot;viewport&quot; content=&quot;width=device-width, initial-scale=1.0&quot;&gt;
  &lt;title&gt;&#123;&#123; .Title &#125;&#125;&lt;/title&gt;
  &#123;&#123; .MetaTags &#125;&#125;
  &lt;link rel=&quot;stylesheet&quot; href=&quot;/style.css&quot;&gt;
&lt;/head&gt;
&lt;body&gt;
  &#123;&#123; .Content &#125;&#125;
&lt;/body&gt;
&lt;/html&gt;</code></pre>

## Template variables

<table>
<thead>
<tr><th>Variable</th><th>Description</th></tr>
</thead>
<tbody>
<tr><td><code>&#123;&#123; .Content &#125;&#125;</code></td><td>The rendered HTML from the Markdown file.</td></tr>
<tr><td><code>&#123;&#123; .Title &#125;&#125;</code></td><td>The <code>title</code> field from frontmatter.</td></tr>
<tr><td><code>&#123;&#123; .Date &#125;&#125;</code></td><td>The formatted date (e.g. <code>November 19, 2024</code>). Only set for feed posts.</td></tr>
<tr><td><code>&#123;&#123; .Author &#125;&#125;</code></td><td>The <code>author</code> field from frontmatter. Only set for feed posts.</td></tr>
<tr><td><code>&#123;&#123; with .PrevInSection &#125;&#125;...&#123;&#123; end &#125;&#125;</code></td><td>For feed posts, renders the block only when an older neighboring post exists. Inside the block, use <code>&#123;&#123; .RelPermalink &#125;&#125;</code> and <code>&#123;&#123; .Title &#125;&#125;</code>.</td></tr>
<tr><td><code>&#123;&#123; with .NextInSection &#125;&#125;...&#123;&#123; end &#125;&#125;</code></td><td>For feed posts, renders the block only when a newer neighboring post exists. Inside the block, use <code>&#123;&#123; .RelPermalink &#125;&#125;</code> and <code>&#123;&#123; .Title &#125;&#125;</code>.</td></tr>
<tr><td><code>&#123;&#123; range .Pages &#125;&#125;...&#123;&#123; end &#125;&#125;</code></td><td>Repeats the block once per page on the site. Inside the block, use <code>&#123;&#123; .RelPermalink &#125;&#125;</code> and <code>&#123;&#123; .Title &#125;&#125;</code>. See <a href="#navigation-menus">Navigation menus</a>.</td></tr>
<tr><td><code>&#123;&#123; .Lang &#125;&#125;</code></td><td>The <code>languageCode</code> from <code>hunim.toml</code>.</td></tr>
<tr><td><code>&#123;&#123; .MetaTags &#125;&#125;</code></td><td>Generated <code>&lt;meta&gt;</code> tags for SEO (og:title, description, canonical URL).</td></tr>
</tbody>
</table>

## Custom templates

A page can use a specific template by setting `template` in its frontmatter:

```markdown
---
title: About
template: wide.html
---
```

Hunim will look for `templates/wide.html` instead of `templates/default.html`.

## Feed templates

Directories marked as feeds automatically look for a template named `{dirname}_list.html`. For a feed in `src/blog/`, create `templates/blog_list.html` to style individual blog posts. See [Feeds](/feeds) for details.

## Components in templates

Templates can include [components](/components) using the component name syntax:

<pre><code class="language-html">&lt;body&gt;
  &#123;&#123; nav &#125;&#125;
  &lt;main&gt;
    &#123;&#123; .Content &#125;&#125;
  &lt;/main&gt;
  &#123;&#123; footer &#125;&#125;
&lt;/body&gt;</code></pre>

## Navigation menus

`{{ range .Pages }}...{{ end }}` repeats its body once for each page on the site, so menus don't need hardcoded links. It works in templates, components, and HTML pages:

```html
<nav>
  <ul>
    {{ range .Pages }}<li><a href="{{ .RelPermalink }}">{{ .Title }}</a></li>
    {{ end }}
  </ul>
</nav>
```

The list holds every Markdown page except drafts, pages with `desc: no-index`, and feed posts (a feed's index page is listed; its posts appear through `{{ .PostList }}`). Pages are sorted by their `weight` [frontmatter](/frontmatter) field, lowest first, then by URL. Pages without a `weight` count as `0`.

## Auto-reload

When you run `hunim server`, a small polling script is injected automatically before the closing `</head>` of every page, so the browser refreshes on file changes. You don't need to add anything to your templates, and production builds (`hunim build`) contain no such script.
