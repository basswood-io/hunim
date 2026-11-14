# 0.6.1

## Fixes
 - `sitemap.xml` now lists pages written directly as HTML (e.g. `src/download.html`, served at `/download`), not just Markdown pages and `index.html` files
 - An HTML page is kept out of `sitemap.xml` when it has a `<meta name="robots">` tag containing `noindex`, regardless of case, quote style, or extra directives like `noindex, nofollow`. The root `404.html` is never listed
 - Markdown `index.md` pages are no longer listed twice in `sitemap.xml`
 - `hunim new` now writes a working `lang` attribute in the starter `index.html` (#9)
