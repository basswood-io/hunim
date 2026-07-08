<p align="center"><a href="https://hunim.org"><img src="https://raw.githubusercontent.com/basswood-io/hunim/master/docs/src/logo.svg?sanitize=true" alt="Hunim" width="300"></a></p>

Awesome static site generator by [basswood-io](https://basswood.io) in Nim.

---

## Overview

Hunim is a static site generator written in the Nim programming language. Small, fast, and unopinionated, it's ready to meet your needs.

## Choose How to Install

```
nimble install https://github.com/basswood-io/hunim
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
hunim server
```

`Ctrl^C` to stop.

When you are ready to deploy your site, run:

```
hunim
```

This publishing the files to the `public` directory.

