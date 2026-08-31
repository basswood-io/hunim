<p align="center"><a href="https://hunim.org"><img src="https://raw.githubusercontent.com/basswood-io/hunim/master/docs/src/logo.svg?sanitize=true" alt="Hunim" width="300"></a></p>

Awesome static site generator by [basswood-io](https://basswood.io) in Nim.

---

## Overview

Hunim is a static site generator written in the Nim programming language. Small, fast, and unopinionated, it's ready to meet your needs.

## Choose How to Install

```
nimble install hunim
```

If you want to contribute, fork this repo, clone it, then run:
```
nimble make
```
to build the binary.

## Usage

Start a new site:
```
hunim newsite mysite
cd mysite
```

Start the development server:
```
hunim serve
```

See the available commands and options with `hunim --help`. The development
server defaults to `127.0.0.1:8080`; use `hunim serve --host 0.0.0.0 --port
8080` to choose a different interface and port. `hunim server` remains
supported as an alias.

`Ctrl^C` to stop.

When you are ready to deploy your site, run:

```
hunim
```

This publishing the files to the `public` directory.
