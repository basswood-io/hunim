# 0.6.0

## Features
 - Added `{{ range .Pages }}...{{ end }}` for building navigation menus without hardcoded links. It repeats once per page with `{{ .Title }}` and `{{ .RelPermalink }}`, skipping drafts, `no-index` pages, and feed posts, ordered by the new `weight` frontmatter field and then by URL
 - Added `titleCase` configuration for filename-derived page titles: `titlecase` (default), `uppercase`, or `lowercase`

## Fixes
 - `hunim server` now serves pages whose names end in a numeric "extension" (e.g. `release-0.5`) as HTML
