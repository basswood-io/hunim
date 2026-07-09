# 0.5.0

## Features
 - Builds now warn about unused templates, components, and exec scripts — files no page reaches, directly or through its template and components
 - Components can now be nested: a component may reference other components, expanded recursively with arguments working at every level. References must be acyclic; a cycle is a build error naming the loop, e.g. `Component cycle: a -> b -> a`
 - `hunim server` now rebuilds incrementally. An edited page rebuilds just itself; an edited template, component, or exec script rebuilds only the pages that use it; a static asset is just re-copied; a change in a feed directory rebuilds that feed. Templates, components, and `hunim.toml` are now watched too. Adding or deleting files, or editing `hunim.toml`, still triggers a full rebuild
 - Added `hunim dag`, which serves an interactive diagram of the site's structure at `http://127.0.0.1:8081`: every page, template, component, and exec script, with edges for their dependencies. Hover a node to trace its dependency chain; refresh to rescan — no build required
