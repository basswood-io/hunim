---
title: Syntax Highlighting
weight: 50
desc: Hunim colors fenced code blocks at build time — no client JavaScript, no flash of unstyled content.
---

# Syntax Highlighting

Hunim highlights fenced code blocks **at build time**. Tokens are wrapped in `<span>`s while the site is generated, so pages ship pre-colored code with no client-side JavaScript and no flash of unstyled content. You supply the colors with CSS.

## Usage

Add a language name to the opening fence — that's it:

````
```nim
import times
echo now().format("yyyy-MM-dd")
```
````

renders as:

```nim
import times
echo now().format("yyyy-MM-dd")
```

A block with no language, or a language Hunim doesn't recognize, is emitted unchanged (still inside `<pre><code>`, just uncolored).

## Turning it off

Highlighting is on by default. If you'd rather ship plain code blocks — for instance because you use a client-side highlighter — disable it in `hunim.toml`:

```toml
[highlight]
enabled = false
```

Blocks are then emitted as plain `<pre><code class="language-…">source</code></pre>`.

## Supported languages

Highlighting uses Nim's built-in tokenizer, so it's dependency-free but covers a focused set of languages:

| Language | Fence names |
|----------|-------------|
| Nim | `nim` |
| C | `c` |
| C++ | `cpp`, `c++` |
| C# | `csharp`, `c#` |
| Java | `java` |
| Python | `python` |
| YAML | `yaml`, `json` |
| Cmd | `cmd`, `bash`, `zsh`, `sh` |

Names are case-insensitive. A couple of names are aliased to a near-enough lexer: `json` uses the YAML lexer (a near-superset of JSON), and `bash`, `zsh`, and `sh` use the `cmd` lexer. Anything else (`html`, `js`, `toml`, …) passes through uncolored.

The `cmd` lexer is tuned for shell command lines — it picks out the program name, its options and arguments, quoted strings, comments, and operators:

````
```cmd
hunim build --drafts
git clone https://github.com/basswood-io/hunim lib/hunim
```
````

renders as:

```cmd
hunim build --drafts
git clone https://github.com/basswood-io/hunim lib/hunim
```

## Styling the tokens

Hunim only emits classes; the colors are yours. Each meaningful token gets one of these classes:

| Class | Token |
|-------|-------|
| `hl-keyword` | Keywords |
| `hl-string` | String and character literals |
| `hl-escape` | Escape sequences like `\n` |
| `hl-number` | Numeric literals |
| `hl-comment` | Comments |
| `hl-operator` | Operators |
| `hl-preprocessor` | Preprocessor / directive lines |
| `hl-regex` | Regular expressions |
| `hl-program` | Command / program name (`cmd`) |
| `hl-option` | Command options, arguments, and quoted strings (`cmd`) |

Identifiers, whitespace, and punctuation are left unwrapped so they inherit the surrounding `pre code` color, keeping the markup light. (In `cmd`, that includes file and directory paths.)

A minimal stylesheet (tuned for a dark code background):

```css
pre code .hl-keyword      { color: #f9e2af; }
pre code .hl-string       { color: #a6e3a1; }
pre code .hl-escape       { color: #f5c2e7; }
pre code .hl-number       { color: #fab387; }
pre code .hl-comment      { color: #7f849c; font-style: italic; }
pre code .hl-operator     { color: #89dceb; }
pre code .hl-preprocessor { color: #f5c2e7; }
pre code .hl-regex        { color: #f2cdcd; }
pre code .hl-program      { color: #89b4fa; font-weight: 600; }
pre code .hl-option       { color: #94e2d5; }
```

## Using Prism.js or highlight.js instead

Client-side highlighters like [Prism.js](https://prismjs.com) and [highlight.js](https://highlightjs.org) find `<pre><code class="language-…">` blocks in the browser and rewrite them with their own token spans. Because they read each block's text content (which ignores Hunim's `<span>`s and recovers the original source), they still work if Hunim has already highlighted a block — but they **re-do the work on every page load and reintroduce the flash of unstyled content** that build-time highlighting exists to avoid.

The two approaches are mutually exclusive in practice, so if you load a client-side highlighter, set `enabled = false` above. Hunim then leaves blocks untouched, giving Prism/highlight.js the clean `language-…` markup they expect — and covering the many languages Hunim's built-in highlighter doesn't.
