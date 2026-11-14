# Spec: oc-html MVP (local HTML viewer)

Source of intent: `docs/intent/mvp.md`.

## Objective

Build `html <file>`, a command that renders a local HTML file as readable text on an OpenComputers screen.

- User: GT:NH (Minecraft 1.7.10) players on OpenComputers with Lua 5.3.
- Why: no public script does this. The MVP proves the idea and is the base for remote browsing.
- Principle: simple but robust. Any input is allowed. When the input breaks a limit, the program detects it early and stops with a clear message. It never crashes with a traceback and never leaves the screen in a bad state.

### User stories

1. As a player, I run `html ./page.html` and see the page text with headings, paragraphs and links shown clearly.
2. As a player, I scroll through a page that is longer than the screen.
3. As a player, I press `q`, confirm, and the viewer exits cleanly.
4. As a player, I open a broken or very large file and get either a usable render or a clear error message.

### Scope of the MVP

In scope:
- Local files only.
- Forgiving parsing of any HTML, including broken markup.
- Text rendering with block structure, emphasis and visible links.
- Scrolling viewer with a status line.
- Quit confirmation.

Out of scope (later roadmap):
- Remote fetching, following links, tabs, shell tab-out, downloads, sessions (save and resume).
- CSS, JS, images.
- Correct layout of tables, lists, forms, `<input>` and `<button>`. These render as plain text and must not break anything.

## Tech Stack

- Lua 5.3 on OpenComputers, OpenOS.
- OpenOS libraries only: `component`, `computer`, `term`, `event`, `keyboard`, `unicode`, `filesystem`, `serialization`, `shell`.
- No other dependencies. The Data Card is optional and is not used in the MVP.
- Lua 5.3 in a Docker container for the automated tests. Tests replace OpenOS libraries with small shims.

## Commands

In game:
```
html [--print] [--width n] [--stats] [--stats-out path] [--no-rescale] <file>
                     render a local HTML file. The viewer is the default
html --print <file>        write the page as text to stdout, without style bytes. The width is the terminal width
html --no-rescale <file>   keep the current screen resolution
html --width n <file>      output width in columns. It turns on --print; use it to compare with test files
html --stats <file>        print the stats lines (below) to stderr
html --stats-out <path> <file>
                           also write the stats lines to <path> (overwrite). Sets --stats
html --help          show usage
html                 (no arguments) show usage. Later: start a new session
html ~/page.html     a leading "~/" (or a bare "~") is the home directory
html-install [--prefix <dir>] [--dry-run]
                     install a release from its one-file installer (see "Releases")
```

Stats lines, in this order:
```
stats: file=<bytes> bytes
stats: width=<columns>              always a number (80 when the screen width is unknown)
stats: lines=<count>
stats: cpu=<seconds> s              os.clock time of the tokenizer and layout
stats: wall=<seconds> s             computer.uptime time of the same part
stats: free_before=<bytes> bytes    settled free memory before the render
stats: free_after=<bytes> bytes     settled free memory after the render
stats: delta=<bytes> bytes (<x> per line)
stats: lowest_free=<bytes> bytes    lowest freeMemory() reading from the render start to the end of the output
stats: peak_used=<bytes> bytes (<x> per line)
stats: settles=<n> gc_seen=<n> settle_yields=<n>
                                    free_before - lowest_free
stats: trace=<line>:<free><mark>,<line>:<free><mark>,...
                                    freeMemory() readings of the guard (from 0.0.3a)
```

- A missing or invalid value prints as `n/a`, for example `stats: lowest_free=n/a`. The stats report never fails on a missing value. A guard function that is missing (a guard module from an older version) or that fails gives `n/a`. When `lowest_free` is missing, it falls back to `free_after`, then to `free_before`.
- `settles` is the number of settles since `guard.reset()` (see Limits and graceful failure). It includes the settle for `free_after`. `gc_seen` is the number of settles that saw a GC. `settle_yields` is the number of yields of all settles. At about 10 ms per yield, `settle_yields` / 100 is the wall time the settles cost, in seconds.
- `trace` holds at most 60 samples, oldest first. A sample is `<line>:<free><mark>`: the last line count given to `guard.tick()` and a `freeMemory()` reading. The mark is empty for a raw reading of a tick, `s` for a settle result and `S` for a settle result that saw a GC, for example `1803:129682s` or `1803:129682S`. The guard keeps every Nth tick and every settle of `tick()`. When 60 samples are full, it drops every second sample and doubles N, so the samples spread across the whole run. When the guard stops the render, the stopping settle result is the last sample. The line stays under about 1000 characters. With no sample, the line is `stats: trace=n/a`. The trace starts at `guard.reset()`, so it covers the render and the output.

- `delta` (free_before - free_after) is unreliable. The game has no `collectgarbage`, so a reading includes garbage, and garbage from earlier work (module loading) can be collected during the run. Measured: delta was -164198 bytes on a 98891-byte page.
- `peak_used` is an upper bound of the peak memory use. `lowest_free` includes garbage that is not collected yet.
- When the render stops with a controlled error, the stats lines still follow the error line. They hold the values known at that point (file, width, free_before, lowest_free, peak_used without the per-line value) and a last line `stats: stopped=<error message>`.
- `--stats-out` writes the same lines with LF endings. A write failure prints one line `html: cannot write stats file: <path> (<reason>)` after the stats lines and gives exit code 1. The page output and the stats on stderr are not affected. The write checks the results of `write`, `flush` and `close` (see "Limits and graceful failure").
- `shell.resolve` does not expand `~` (measured: it gives `/home/~`). So `bin/html.lua` replaces a leading `~/` or a bare `~` in the file argument and in the `--stats-out` path with the home directory before `shell.resolve`. The home directory is `os.getenv("HOME")`, or `/home` when it is not set. `~user` is not expanded.

On the host (from the project root, Docker Desktop running):
```
docker build -t oc-html-test tests/docker      build the test image (once, or after a Dockerfile change)
pwsh tests/docker/test.ps1                     run all unit and corpus tests
pwsh tests/docker/test.ps1 fuzz 1000           run 1000 fuzz documents through the pipeline
```

Inside the container, the script runs `lua5.3 tests/run.lua` and `lua5.3 tests/fuzz.lua <n>`.

## Releases

A release is a fixed copy of the in-game files.

- Path: `releases/<version>[suffix]/<output>`.
- Version: `major.minor.patch`. Suffix `a` is alpha, `b` is beta, no suffix is a real release.
- Plan: the tracer bullet is `0.0.1a`. Test builds before the MVP are `0.0.x` with `a`. The MVP is `0.1.0a`.
- `0.0.2a`: peak-memory stats, `--stats-out`, and the first one-file installer.
- `0.0.3a`: clears cached `html.*` modules (fixes the `lowest_free` crash after an update), `n/a` for missing stats values, and the `trace` stats line. `tools/memprobe.lua` is fetched from `tools/` and is not part of a release.
- `releases/latest` is a symlink to the newest release folder. It does not resolve on the user's host (it shows as a plain file that holds the version text). It stays for local use. Fetch by version path, for example `releases/0.0.2a/html-install.lua`.
- Each release folder has `release.tar.gz` with the bin and lib files: the same files as `files.txt`, with the same relative paths.
- Unpacking a `.tar.gz` in game needs gzip inflate and a tar program. The test machine has no data card, and OpenOS has no tar by default. So in game, fetch `html-install.lua` (from 0.0.2a) or the single files. The tarball is for transfer outside the game.

Release command (from the project root, Docker Desktop running):
```
pwsh tools/release.ps1 0.0.1a
```

The script stops when:
- the version does not match `major.minor.patch` with an optional `a` or `b`,
- `releases/<version>` already exists (a release is never overwritten),
- `bin/` or `lib/` has uncommitted changes (a release always matches a commit),
- `pwsh tests/docker/test.ps1` fails.

Then it copies the files, writes `files.txt`, creates `release.tar.gz` (ustar format, sorted names, owner and group 0, made with the Windows `tar.exe`), creates `html-install.lua` and updates `releases/latest`. If a real symlink cannot be created, it records the link in the git index only.

Layout (mirrors the in-game paths under `/home`):
```
releases/<version>/bin/html.lua         goes to /home/bin/html.lua
releases/<version>/lib/html/*.lua       goes to /home/lib/html/
releases/<version>/files.txt            one relative path per line, sorted, LF endings
releases/<version>/release.tar.gz       the files in files.txt, same relative paths (gzip, ustar)
releases/<version>/html-install.lua     one-file installer that holds the files in files.txt (from 0.0.2a)
```

`files.txt` lists neither `release.tar.gz` nor `html-install.lua`.

The script checks the tarball: the list equals `files.txt`, and each extracted file is byte-identical to the release copy. It stops with an error if a check fails.

### Installer

`html-install.lua` installs a release with one fetch. It needs no data card and no other script.

```
wget -f <BASE>/releases/<version>/html-install.lua /home/html-install.lua
/home/html-install.lua [--prefix <dir>] [--dry-run]
```

- The default prefix is `/home`. It writes `<prefix>/bin/html.lua` and `<prefix>/lib/html/*.lua`, and creates the folders.
- `--dry-run` runs the checks and lists the files. It writes nothing.
- Output: `html-install: oc-html <version>`, one line `<path> <size> bytes` per file, then `installed N files`.
- Checks before any write:
  - each embedded file has the size recorded at build time (a short download fails here or as a syntax error),
  - no target path is a directory,
  - the target filesystem (`filesystem.get(path)`) is not read-only,
  - free space (`spaceTotal() - spaceUsed()`) is at least the sum of the file sizes, plus the largest file (for the temporary copy), plus 1024 bytes per file. Old files that the install replaces are not counted.
- Write order:
  1. Each file goes to `<target>.new` in the target folder. The installer reads it back and compares it with the embedded content.
  2. When all temporary files are correct, each old file moves to `<target>.old`, and `<target>.new` is renamed to `<target>`. Rename over an existing file replaces it (measured on tmpfs and on the HDD). The move-aside step is kept as a safe rollback.
  3. The `.old` files are removed.
- On any failure, the installer removes its temporary files, puts the old files back, and prints one line `html-install: <reason>; old files kept`. An unexpected error also prints one `html-install: ` line. The exit code is 1 (2 for bad arguments).
- Loaded with a table as the first argument, the chunk returns its module: `VERSION`, `files` (relative path to content), `sizes` and `main(argv, deps)`. The tests use this with a fake filesystem.

How it is built:
- `tools/installer.lua` is the template with the install logic. `tools/mkinstall.lua` replaces its `-- @@FILES@@` line with the version and one long-bracket string per file in `files.txt`.
- The long-bracket level is the lowest level whose close bracket first appears at the end of `content .. close`. Lua drops a newline right after the opening bracket, so the generator always writes one there.
- The generator refuses content with a carriage return (Lua turns `\r` and `\r\n` in a long string into `\n`), bad or duplicate paths, and a bad version. It loads the result and compares every file before it prints the source.
- `release.ps1` runs the generator in the test container (sandbox flags, repository read-only) and redirects stdout to the file. Then it runs `luac5.3 -p` on the installer and `lua5.3 tools/mkinstall.lua --check <version> releases/<version>`, which compares the embedded files with `files.txt` and the release copies.

Add only the tarball to an existing release that has none:
```
pwsh tools/release.ps1 -TarballOnly 0.0.1a
```
`-TarballOnly <version>` runs the same tar command and checks, and changes no other file. It stops if `release.tar.gz` already exists.

`files.txt` lists the files of the release, not itself. The installer generator reads it.

## Project Structure

```
bin/html.lua            entry point: argument parsing, error boundary, screen restore
lib/html/guard.lua      yield timing and memory checks, shared by all stages
lib/html/entities.lua   named and numeric entity decoding
lib/html/text.lua       UTF-8 cleaning and the chunk split helper
lib/html/tokenizer.lua  streaming, forgiving tokenizer (reads the file in chunks)
lib/html/layout.lua     turns tokens into wrapped, styled lines (no DOM tree)
lib/html/viewer.lua     screen drawing, scrolling, keys, quit prompt
tests/run.lua           desktop test runner
tests/*_test.lua        unit tests, one file per module
tests/shim/             desktop replacements for OpenOS libraries
tests/cases/            small hand-written HTML files with expected output
tests/pages/            generated test pages (large.html: about 1 MB, from tools/genpage.lua)
tests/real/             saved real-world pages
tests/fuzz.lua          random and mutated HTML generator
tests/docker/Dockerfile test image: alpine:3.20 with the lua5.3 package only
tests/docker/test.ps1   runs the tests in the container with the sandbox flags
docs/intent/mvp.md      confirmed statement of intent
docs/probe/             in-game probe outputs and FACTS.md (measured machine facts)
docs/ingame/            in-game test steps, one file per task
tools/release.ps1       publishes a release and updates releases/latest
tools/installer.lua     installer template (install logic)
tools/mkinstall.lua     builds and checks releases/<version>/html-install.lua (runs in the container)
tools/genpage.lua       deterministic generator of tests/pages/large.html (runs in the container)
tools/memprobe.lua      in-game memory experiments (Task 3c). Not part of a release
releases/               published release folders and the latest symlink
types/openos.lua        LuaLS type stubs for OpenOS
.luarc.json             LuaLS settings (Lua 5.3, loads types/)
SPEC.md                 this file
```

Modules load only when needed. A stage releases its data when the next stage no longer needs it.

## Design

### Pipeline

1. `bin/html.lua` checks arguments and the file. It runs the rest inside `xpcall`.
   - OpenOS keeps every required module in `package.loaded` until a reboot. No code removes an entry, and every program shares the same table. So after an update, `require` can return the module of an older version. (Seen in 0.0.2a: the new `bin/html.lua` called `guard.lowest_free`, which the cached 0.0.1a guard did not have.)
   - `bin/html.lua` removes every `package.loaded` key that starts with `html.` when the chunk loads, before its first `require`. `M.run_program` runs `main` in `pcall` and removes the keys again on every exit path (normal, error, Ctrl+C), then raises the error again. This loads the current code after an update and frees the module memory after a run.
   - `M.clear_modules(loaded)` does the removal and returns the count. Other keys stay.
2. `tokenizer` reads the file with `io` in 4096-byte chunks and produces tokens one at a time: start, end and text tokens only. Comments, doctype, CDATA and processing instructions are skipped. It is built on plain `string.find` and `string.byte`. It never runs `gsub` or `gmatch` over large strings (measured: `gsub` 94 KB/s, plain `find` 6338 KB/s).
   - Measured costs (probe v2): plain `find` about 3.2 us per call (6821 KB/s), `string.byte` of 1 byte about 61 ns, `sub` of 80 bytes about 260 ns, `t[#t+1] = v` 17.2 M ops/s against `table.insert` 9.0 M.
   - Use plain `find` for long jumps: to the end of a text run (`<`), to `-->` and to `</script`. Use `byte` inside tags, where the parts are short. Use `sub` to cut the text of a token. Use `t[#t+1] = v` for appends.
3. `layout` consumes tokens, keeps a small stack of open elements, and appends finished lines. A line is one string with inline style control bytes (measured: 80 bytes per line; a table of styled pieces used 322).
   - Bytes 0x01 to 0x05 select a style: normal, heading, emphasis, link, preformatted. A style lasts until the next style byte.
   - Text never contains these bytes, because cleaning removes control bytes first (see "Text cleaning").
   - Style bytes never count toward the line width.
   - Every non-empty line starts with its style byte. An empty line is "".
4. `viewer` draws the lines and handles keys.

The tokenizer and layout never call `component`. They take `guard` as their only link to the machine.

### Parsing rules

- Never raise an error on bad markup.
- A "<" with no ">" within `MAX_TAG` (16384) bytes becomes text. This bounds the buffer.
- Unclosed tags close at the end of the document or when a parent closes.
- A stray end tag with no matching open tag is ignored.
- Unknown tags are treated as inline. Their content is kept.
- The tokenizer produces start, end and text tokens only. Comments, doctype, CDATA and processing instructions are skipped. An unclosed one ends with the input.
- Implied ends: a block or heading start closes an open `p`. `li` closes an open `li` (it stops at `ul` or `ol`). `dt` and `dd` close each other (they stop at `dl`). `tr`, `td` and `th` close the open row or cell (they stop at `tr` or `table`). `option` closes an open `option`. `body` closes `head`. The stack of open elements has a depth bound of 256.
- Attribute values may be quoted or unquoted. Broken attributes are dropped.
- Text is treated as UTF-8 and is cleaned before any `unicode.*` call (see "Text cleaning").
- Entities: the common named entities (`&amp; &lt; &gt; &quot; &apos; &nbsp; &copy; &reg; &mdash; &ndash; &hellip;` and similar) and numeric `&#N;` and `&#xN;`. An unknown entity stays as written.
  - Named entities: the list above, all Latin-1 names and a set of common typographic names. Names are case-sensitive.
  - Numeric references 128 to 159 use the Windows-1252 table.
  - A numeric reference without ";" decodes. Only amp, lt, gt, quot, nbsp, copy and reg decode without ";", and only when the next byte is not a letter, digit or "=".
  - A reference to 0, a surrogate or a code point above U+10FFFF gives "?". A reference to a control or invisible character gives "".

### Element handling

| Elements | Rendering |
|---|---|
| `script style template svg math iframe object noscript` | Dropped with all content |
| `head` | Dropped, but `title` text goes to the status line |
| `h1`-`h6` | Own block with a blank line before and after, heading color |
| `p div section article main header footer nav aside blockquote dt dd` | Block break |
| `br` | Line break |
| `hr` | A full-width line of `─` |
| `b strong i em u mark` | Emphasis color |
| `a` with `href` | Link color. Not clickable in the MVP |
| `pre` | Whitespace kept, long lines wrapped |
| `code` | Kept as inline text |
| `img` | `[img: <alt>]`, or `[img]` when there is no alt text |
| `li` | Block break with a `- ` prefix |
| `table tr td th ul ol dl form input button select textarea` | Block breaks only, content as plain text |
| Any other tag | Inline, content kept |

Whitespace collapses to one space outside `pre`. Lines wrap at word boundaries to the screen width. Width uses `unicode.wlen` on the cleaned text so wide characters fit.

Tabs: the game draws a tab as a 2-cell glyph (measured: `wlen("a\tb")` = 4). Inside `pre`, the layout expands each tab to spaces up to the next 8-column stop before it measures the width. Outside `pre`, the whitespace collapse removes tabs.

### Text cleaning

`unicode.*` never throws on bad bytes. It turns them into U+FFFD and can count a wrong width. `utf8.len` accepts encoded surrogates. So the program cleans all text before any `unicode.*` call:

- Invalid sequences, truncated sequences, overlong forms and encoded surrogates (U+D800 to U+DFFF) become `?`.
- One `?` replaces each maximal invalid subpart (Unicode recommended practice). So an encoded surrogate gives 3 `?` (the game shows one U+FFFD).
- DEL 0x7F and the C1 controls U+0080 to U+009F are removed.
- The removed zero-width and invisible characters are U+00AD, U+200B, U+200C, U+200D, U+200E, U+200F and U+FEFF. (`unicode.wlen` counts U+200B as width 2.)
- The variation selectors U+FE00 to U+FE0F are removed. (U+FE0F is wide in the game: `wlen` 2, measured.)
- Control bytes below 0x20 are removed, except tab and newline. `\r` is removed.
- Decoded entities pass through the same rules.
- The tokenizer calls `entities.decode(text.clean(s))`. A partial UTF-8 sequence or entity at a chunk end is held back with `text.split_tail` and joined to the next chunk.

### Viewer

- The last screen row is a status line: page title (or file name), scroll position in percent, and a key hint.
- Keys: Up/Down one line, PgUp/PgDn one screen, Home/End to the start and end, `q` to quit.
- Key codes. The standard codes 199 (Home), 200 (Up), 201 (PgUp), 207 (End), 208 (Down) and 209 (PgDn) are always accepted. The NumPad codes 71 (Home), 72 (Up), 73 (PgUp), 79 (End), 80 (Down) and 81 (PgDn) are accepted only when the `key_down` char is 0. A NumPad digit (NumLock on, for example code 73 with char '9') never acts as a navigation key. Measured: the user's keyboard sends PgUp, PgDn, Home and End as NumPad codes with char 0.
- `q` shows the prompt "Quit? (y/n)". `y`, `Y` or Enter quits. Any other key cancels.
- Ctrl+C quits at once, without the prompt. It arrives as `key_down` with char 3, then an "interrupted" event from `event.pull` (measured, not an error). The viewer quits on either one.
- Key repeat sends about 28 events per second after 500 ms (measured). Before a redraw, the viewer takes all queued scroll events and adds them up, so one redraw covers them.
- On start, the viewer sets the resolution to `gpu.maxResolution()` if the current resolution is different. `--no-rescale` skips this.
- The viewer then reads the size with `gpu.getResolution()`.
- On every exit path, the viewer restores the resolution it found at start.
- Measured: t3 had 120x60 on a GPU with a 160x50 maximum. This was a user-set resolution.
- Colors depend on `gpu.getDepth()`. Depth 8 and 4 use colors for headings, links and emphasis, given as RGB values. Depth 1 uses plain text, white on black. Palette indices are not used.
- Color values: NORMAL 0xFFFFFF, HEADING 0xFFFF33, EMPHASIS 0xFFCC33, LINK 0x6699FF, PRE 0x33CC33. The status line is black on white.
- The viewer caches the current foreground and background. It calls `setForeground` and `setBackground` only on a change (measured: a call costs as much as a `fill`, also with the same color). Both calls return the old color (measured).
- Scrolling moves the screen content with `gpu.copy` and draws only the new rows. `copy` leaves the source row as it was (measured), so the viewer always draws the new row. A scroll of up to h-2 lines (including PgUp, PgDn and short Home or End jumps) uses `copy` and draws only the exposed rows. A larger jump redraws all rows.
- One `gpu.set` call draws one same-style piece of a line. A call costs the same for 1 or 160 characters.
- On exit (normal, error or Ctrl+C) the viewer restores the colors and the resolution, calls `term.clear()` and sets the cursor. The `term` cursor is stale after direct GPU drawing (measured), so the viewer must set it.
- `--stats` lines print after the screen restore, so they stay on the screen.

### Limits and graceful failure

There are no fixed size caps. The program measures and stops before damage happens.

- `guard.tick()` runs once per token, once per text token in layout and once per emitted line (not per byte). It measures time with `os.clock()`, which has sub-millisecond steps (`computer.uptime()` moves in 50 ms steps). It yields with `os.sleep(0)` when more than `YIELD_INTERVAL` (1 s) has passed since the last yield. This is well below the 5 second OpenOS timeout. `guard.reset()` restarts the yield timer, and the tests use it. `guard.settled_free()` is public. It runs one settle (up to 11 yields, see below) and returns the highest `freeMemory()` reading. `guard.settles()`, `guard.gc_seen()` and `guard.settle_yields()` return the settle counters. `reset()` clears them. `guard.lowest_free()` returns the lowest `freeMemory()` reading that `tick()` and `settled_free()` saw since the last `reset()`, or nil. `reset()` clears it. `--stats` uses it for `lowest_free` and `peak_used`. `guard.trace_text()` returns the memory trace (see the `trace` stats line), or "" when it is empty. `reset()` clears it too.
- `guard.tick()` also checks `computer.freeMemory()` against the effective reserve, in `freeMemory()` units (real bytes / ramScale, measured ramScale 1.800). The effective reserve is max(`MEMORY_RESERVE`, next_doubling). `MEMORY_RESERVE` is 192 KB. next_doubling = 32 * c / 1.8, where c is the smallest power of two >= the current line count (at least 1024). Reason: the lines table holds one slot per line. When it is full, Lua doubles its array from c to 2c slots and keeps the old slots until the copy ends, so the doubling needs 2c slots of 16 real bytes at once. Measured: the 8192 to 16384 doubling cost 72818 units, and on large.html free memory hit 0 at that doubling (0.0.4a). For c = 8192 the term is 145636 (under the base reserve). For c = 16384 it is 291271. `guard.reserve()` returns the effective reserve. A raw reading can be up to about 1.3 MB too low (measured), because garbage is not collected yet. The readings form a saw-tooth, because the incremental GC frees garbage during the render. Garbage never makes an allocation fail: a failed allocation runs a full GC and retries.
- Settle (guard v2). The OpenOS kernel runs a full GC on every 10th resume of the main coroutine (measured). A settle yields with `os.sleep(0)` up to 11 times and reads `freeMemory()` after each yield. A rise above the previous reading by more than max(16384, 5% of the previous reading) is a GC. The settle stops at the first GC and returns the highest reading. When it sees no GC in 11 yields, it returns the highest reading and records that it saw no GC. A settle costs up to about 110 ms wall time (10 ms per yield).
- Settle rule in `tick()`. A raw reading under the reserve settles only when the rate limit allows it. After a settle at line L with result F, the wait is gap = max(25, (F - reserve) / (2 * B)). B is the live cost per line in `freeMemory()` units: 100 at the start, then the highest cost measured between two settles that saw a GC, but at least 80. Measured in 0.0.4a: about 66.5 per line on large.html, 46 to 76 between settles that saw a GC. (The 0.0.3a values of 160 and 410 were a wrong estimate.) At B per line, one gap uses at most half of the headroom F - reserve. The next settle comes when the line count grew by gap, or when it grew by gap / 2 and a raw reading is under reserve / 2. The second case covers lines that cost up to 2 * B. A `tick()` without a line count uses the tick count in place of the line count.
- Between settles, a raw reading under the reserve does not stop the render. A raw reading under reserve / 2 after a settle that saw no GC stops the render at once: without a GC, no settle lifts it over the reserve. Otherwise only a settle result under the reserve raises the controlled error "html: page too large for available memory (rendered N lines before stopping)".
- Rule change from the first draft: the first draft settled on every raw reading under reserve / 2 and kept B at 410 or more. On a simulated 11302-line run with the measured saw-tooth, that gave 37 settles and 3.7 s of settle yields. The rule above gives 9 settles and 88 yields (0.9 s). With the doubling term and the new cost constants it gives 13 settles and 127 yields (1.3 s): the higher reserve above 8192 lines adds settles. In game, 0.0.4a gave 12 settles and 118 yields on large.html.
- Fail-safe. Every settle saw a GC or used all 11 yields. If OpenOS ever stops the 10th-yield GC, a settle cannot lift a low reading, so the guard stops early with the controlled message. It never crashes and never loops. The tests check this with the GC turned off in the shim.
- Decision against a forced GC: the guard does not force a GC with an oversized allocation. The measured kernel GC on every 10th yield is enough. The trick depends on the behavior of a failed allocation, which is not measured in game.
- The program never calls `collectgarbage`. OpenComputers removes it on purpose.
- Before parsing, `bin/html.lua` compares the file size with free memory. If the file clearly cannot fit, it stops before reading.
- Controlled errors are strings with the prefix `html: `, raised with `error("html: <reason>", 0)`. `bin/html.lua` prints such a message as it is. Any other error value is unexpected: `bin/html.lua` prints one line and writes the full traceback to `/tmp/html-error.log`. This design does not depend on how error tables pass through `pcall` and `xpcall` (see `docs/probe/FACTS.md`, run t3), This is simpler than error tables.
- `/tmp` is only 64 KB. `/tmp/html-error.log` is capped at 8 KB. When the log would grow past the cap, the oldest content is dropped and the newest is kept.
- On a full `/tmp`, `write` returns success because it is buffered. The error "not enough space" shows at `flush` or `close` (measured). So every file write (the error log, `--stats-out`) checks the results of `write`, `flush` and `close`. A failure gives one `html: ` line. When the error log cannot be written, the unexpected error line ends with `(cannot write /tmp/html-error.log: <reason>)` in place of `(details in /tmp/html-error.log)`.
- `bin/html.lua` takes the traceback function as a parameter, because the test sandbox removes `debug`. In game it gets `debug.traceback`.
- Ctrl+C (`key_down` char 3, or the "interrupted" event) exits cleanly and restores the screen.
- Ctrl+C during the render works through an "interrupted" listener and `guard.set_interrupt_check`. It gives `html: interrupted`.
- With no GPU or no screen, the program falls back to print mode and writes one line to stderr.
- An empty file shows an empty page.
- The size check stops before reading when size x 0.5 is more than the settled free memory.
- Messages: `html: file not found: <file>` and `html: not a file: <file>`.
- Exit codes: 0 quit, 1 error, 2 bad arguments, 130 Ctrl+C (also from the viewer).

## Code Style

- Two-space indent. All variables are `local`. No globals.
- Each module returns a table `M`.
- Library functions return values. Only `guard` raises controlled errors. Only `bin/html.lua` prints errors.
- Names: `snake_case` for functions and variables, `UPPER_CASE` for constants.
- Comments explain only related information, such as why a limit exists.

```lua
local computer = require("computer")

local M = {}

-- OpenOS kills a program that runs for 5 s without yielding.
local YIELD_INTERVAL = 1
local MEMORY_RESERVE = 192 * 1024

local last_yield = os.clock()

local function yield()
  os.sleep(0)
  last_yield = os.clock()
end

function M.tick(lines)
  if os.clock() - last_yield > YIELD_INTERVAL then
    yield()
  end
  -- See lib/html/guard.lua for the settle and its rate limit.
end

return M
```

## Testing Strategy

- Errors and `--stats` output go to stderr.
- The runner helper `t.load_bin(name)` loads `bin/<name>.lua` as a text chunk in the same sandbox env. `bin/html.lua` returns its module table when its first argument is a table, so tests can call `M.main(argv, deps)`.
- All automated tests run in Docker. Shims in `tests/shim/` replace `computer`, `unicode` and other OpenOS libraries. The `computer` shim can simulate low memory and `freeMemory()` jitter.
- The shims copy the measured behavior in `docs/probe/FACTS.md` exactly, including the `unicode.*` results for invalid bytes, surrogates and U+200B.
- The sandbox env has no `collectgarbage`, like the game.
- Unit tests: tokenizer (each parsing rule), entities, layout (each row of the element table, wrapping, whitespace).
- The runner helper `t.load_tool(name)` loads `tools/<name>.lua` the same way. `t.read_repo(path)` reads a file under `releases/<version>/` or `tools/` (read-only, no `..`). `t.release_versions()` lists the release folders. `t.list_cases()` lists the base names of `tests/cases/*.html`, sorted. The env `io.open` limit stays as it is. The user approved these helpers.
- Module cache tests use a fake `package.loaded` table: `M.clear_modules`, the chunk load with a fake global `package`, and `M.run_program` on a normal exit and on an error.
- memprobe tests: `tools/memprobe.lua` with fake machine links (step 1 and 2, reboot, failed allocation, errors, Ctrl+C, write failure).
- Installer tests: the template with a fake filesystem (install, upgrade, dry run, short space, read-only, write, read-back and rename failures), the long-bracket encoder, and every `releases/*/html-install.lua` against its release files (skipped while no release has one).
- Corpus tests: each file in `tests/cases/` has an expected text output. Each file in `tests/real/` must render without an error and with more than zero lines.
- Large page: `tests/pages/large.html` renders at width 160 with no uncontrolled error. The test prints its size, line count and CPU time. To make the page again: `docker run ... oc-html-test lua5.3 tools/genpage.lua > tests/pages/large.html` (same flags as `test.ps1`). The fixed seed gives the same bytes.
- Fuzz tests: `tests/fuzz.lua` generates random tag soup and mutates files from the corpus (cuts, duplicated tags, random bytes). Every document must finish with lines or a controlled error. Any other error fails the run and saves the input to `tests/fuzz-failures/`.
- In-game checks (manual, on a depth-8, a depth-4 and a depth-1 screen): the real-world pages, scrolling, quit prompt, resume, the low-memory error and the screen restore after an error.

### Sandbox

Two layers protect the host.

Container (`tests/docker/test.ps1` passes these flags):
- `--rm --network none --read-only`
- `--cap-drop ALL --security-opt no-new-privileges --user 1000:1000`
- `--memory 256m --pids-limit 64`
- The repository is mounted read-only at `/src`. Only `tests/fuzz-failures/` is mounted writable.

Lua environment (`tests/run.lua` and `tests/fuzz.lua`):
- Modules load with `loadfile(path, "t", env)`. Binary chunks are refused.
- `env` has no `os.execute`, `io.popen`, `os.remove`, `os.rename`, `os.exit`, `load` of binary chunks, or `debug`.
- `io.open` in `env` opens files for reading only, and only under `tests/`.

## Boundaries

- Always:
  - Keep `tokenizer` and `layout` free of `component` calls.
  - Run `pwsh tests/docker/test.ps1` and a fuzz run before calling a task done.
  - Restore the screen on every exit path.
  - Add a failing input to the tests when a bug is found.
- Ask first:
  - Add any library outside OpenOS.
  - Move an item from "out of scope" into the MVP.
- Never:
  - Assume input is valid HTML or valid UTF-8.
  - Read the whole file into memory before checking its size.
  - Require the Data Card or an Internet Card for the MVP.
  - Show a raw traceback on the screen.
  - Run test code on the host outside the container.
  - Remove a sandbox flag or widen the Lua environment without asking.
  - Change or delete a published release folder. (One exception: release.tar.gz was added to 0.0.1a after publishing, at the user's request.)

## Success Criteria

1. `pwsh tests/docker/test.ps1` passes all unit and corpus tests.
2. `pwsh tests/docker/test.ps1 fuzz 1000` finishes with zero uncontrolled errors.
3. With the low-memory shim, a large page stops with the controlled memory message.
4. In game on tier 3: three saved real-world pages render with readable headings, paragraphs and links, and scroll with all listed keys.
5. In game: a page of about 1 MB does not hit "too long without yielding". It either renders or stops with the controlled memory message. Expect about 10 to 25 s on a 2 MiB machine.
6. In game: `q` shows the prompt. Cancel returns to the page. Quit exits cleanly.
7. In game on a depth-4 and a depth-1 screen: the page renders with the reduced colors or plain text.
8. After any error, the screen colors are normal and the shell prompt is usable, and the original resolution is restored.

## Later: sessions (not in the MVP)

Agreed design, to be specified after the MVP:
- Each session has an 8-digit lowercase hex ID, for example `4cb2faad`.
- `html` with no arguments starts a new session.
- `html -r <id>` resumes that session. `html -r` resumes the last session.
- The stored content and the storage location are decided when this feature is specified.

## Decisions

- Saved state is not in the MVP.
- The project uses git.
- OCEmu is deprecated. Do not use it.
- Automated tests run in Docker with the sandbox in "Testing Strategy".
- The default branch is `master`.
- Ground-truth machine facts are in `docs/probe/FACTS.md`.

## Open Questions

None.
