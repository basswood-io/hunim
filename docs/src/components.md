---
title: Components
desc: Create reusable HTML snippets and embed them in templates and pages.
---

# Components

Components are reusable HTML snippets stored in the `components/` directory. They can be embedded in templates, HTML source files, and Markdown files alike.

## Basic usage

Create a component file, for example `components/header.html`:

```html
<header>
  <a href="/">Home</a>
  <a href="/blog">Blog</a>
  <a href="/about">About</a>
</header>
```

Then reference it anywhere with the component name (without the `.html` extension):

<pre><code>&#123;&#123; header &#125;&#125;</code></pre>

Hunim replaces the tag with the file's contents at build time. A component named `nav` would live in `components/nav.html` and be referenced as `{{ nav }}`.

## Components with parameters

Components accept positional string arguments. Inside the component file, reference them as `{{ $1 }}`, `{{ $2 }}`, etc.

`components/button.html`:
```html
<a href="{{ $1 }}" class="btn">{{ $2 }}</a>
```

Usage:
```
{{ button "/getting-started" "Read the docs" }}
```

Output:
```html
<a href="/getting-started" class="btn">Read the docs</a>
```

## Nesting components

A component may reference other components, which are expanded recursively at build time — a `card` component can use a `button` component, which can use an `icon` component, and so on. Arguments still work at every level.

Component references must be acyclic: if `a` references `b` and `b` references `a` (or a component references itself), the build fails with an error naming the cycle, e.g. `Component cycle: a -> b -> a`.

## NimScript execution

Files ending in `.nims` in the `components/` directory can be run at build time. Their standard output replaces the tag in the page.

`components/build_time.nims`:
```nim
import times
echo now().format("yyyy-MM-dd")
```

Invoke a script using the exec tag (double curly braces around `exec scriptname.nims`):

<pre><code>&#123;&#123; exec build_time.nims &#125;&#125;</code></pre>

This embeds the current build date into the page. Any `.nims` file in `components/` can be executed this way.

### Requirements

- The file must be in the `components/` directory.
- The filename must end with `.nims`.
- The Nim compiler must be installed and on your `PATH`.
- The script's `stdout` is used as the replacement content.

NimScript gives you access to Nim's standard library, so you can read files, call `httpclient`, or generate any HTML dynamically at build time.

## Caching

All components are loaded into memory at startup and reused for each file. There is no per-page filesystem read — the cache is invalidated when the server detects a change and triggers a rebuild.
