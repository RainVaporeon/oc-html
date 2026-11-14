# oc-html

A minimalistic and lightweight HTML viewer, intended for OpenComputers running on Lua 5.3 architecture to access and browse HTML files.

## status

Release 0.2.0a renders local files and fetches remote pages (`http://` and `https://`) with the Internet Card. Remote fetching is not yet verified in game. Navigation and the subfeatures below are planned; see `tasks/todo.md`. Specification: `SPEC.md` (index) and `spec/` (one file per component). Handoff for a new session: `docs/HANDOFF.md`.

## scope

Local files can be rendered by: `html ./index.html`

Remote files can be rendered by: `html http(s)://example.com/`

Note: Javascript and CSS is not considered when rendering, this intends to be a minimalistic implementation of a HTML viewer/browser.

## features

This script aims to be capable of rendering basic HTML pages, make web requests and browse the web (internet card needed.)

Navigation of the web is supported as well; in short, this is a best-effort approach to implement `links` in OpenComputers. 

### subfeatures

Inside the interface, the following features are available:

- Website tabs: Keeping track of open tabs and its states.
- Shell: Allows to "tab out" of a browsing session to use the shell.
- Download: Downloading a webpage or files.
- Session Retention: Allows the user to save their browsing state to be resumed across restarts.

## install

The script works out of the box. Simply run `html --help` to get started with the info.

In game, install a release with its one-file installer: fetch `releases/<version>/html-install.lua` (for example with `wget`) and run it. It writes `/home/bin/html.lua` and `/home/lib/html/*.lua`. See `spec/installer.md`.

## requirements

For remote files, the running computer should have an Internet Card and the server must allow web requests. Local files will be displayed as usual.

The computer is expected to have sufficient storage to store temporary caches as well as 2 sticks of Tier 3 Memory for best performances. Data Card can be installed for the `inflate` and `deflate` functionality which may save traffic.

## future goals

In the future, this script aims to be able to display images (requiring a Tier 2 or 3 Graphics Card.)

This is a rather far-fetched goal but has been proven to work; the goal aims to render as closely as possible to the provided images. PNGs would be prioritized over other extensions if the expected workload is too big.