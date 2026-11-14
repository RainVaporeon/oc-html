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
html [--width n] [--stats] [--no-rescale] <file>
                     render a local HTML file
html --no-rescale <file>   keep the current screen resolution
html --width n <file>      output width for stdout mode; use it to compare with test files
html --stats <file>        print file size, line count, CPU and wall time, and settled free
                           memory before and after, to stderr
html --help          show usage
html                 (no arguments) show usage. Later: start a new session
```

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
- `releases/latest` is a symlink to the newest release folder. It does not resolve on the user's host (it shows as a plain file that holds the version text). It stays for local use. Fetch by version path, for example `releases/0.0.1a/bin/html.lua`.
- Each release folder has `release.tar.gz` with the bin and lib files: the same files as `files.txt`, with the same relative paths.
- Unpacking a `.tar.gz` in game needs gzip inflate and a tar program. The test machine has no data card, and OpenOS has no tar by default. So in game, fetch the single files. The tarball is for transfer outside the game.

Release command (from the project root, Docker Desktop running):
```
pwsh tools/release.ps1 0.0.1a
```

The script stops when:
- the version does not match `major.minor.patch` with an optional `a` or `b`,
- `releases/<version>` already exists (a release is never overwritten),
- `bin/` or `lib/` has uncommitted changes (a release always matches a commit),
- `pwsh tests/docker/test.ps1` fails.

Then it copies the files, writes `files.txt`, creates `release.tar.gz` (ustar format, sorted names, owner and group 0, made with the Windows `tar.exe`) and updates `releases/latest`. If a real symlink cannot be created, it records the link in the git index only.

Layout (mirrors the in-game paths under `/home`):
```
releases/<version>/bin/html.lua         goes to /home/bin/html.lua
releases/<version>/lib/html/*.lua       goes to /home/lib/html/
releases/<version>/files.txt            one relative path per line, sorted, LF endings
releases/<version>/release.tar.gz     the files above except files.txt, same relative paths (gzip, ustar)
```

The script checks the tarball: the list equals `files.txt`, and each extracted file is byte-identical to the release copy. It stops with an error if a check fails.

Add only the tarball to an existing release that has none:
```
pwsh tools/release.ps1 -TarballOnly 0.0.1a
```
`-TarballOnly <version>` runs the same tar command and checks, and changes no other file. It stops if `release.tar.gz` already exists.

`files.txt` lists the files of the release, not itself. A later installer reads it.

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
tests/real/             saved real-world pages
tests/fuzz.lua          random and mutated HTML generator
tests/docker/Dockerfile test image: alpine:3.20 with the lua5.3 package only
tests/docker/test.ps1   runs the tests in the container with the sandbox flags
docs/intent/mvp.md      confirmed statement of intent
docs/probe/             in-game probe outputs and FACTS.md (measured machine facts)
docs/ingame/            in-game test steps, one file per task
tools/release.ps1        publishes a release and updates releases/latest
releases/               published release folders and the latest symlink
types/openos.lua        LuaLS type stubs for OpenOS
.luarc.json             LuaLS settings (Lua 5.3, loads types/)
SPEC.md                 this file
```

Modules load only when needed. A stage releases its data when the next stage no longer needs it.

## Design

### Pipeline

1. `bin/html.lua` checks arguments and the file. It runs the rest inside `xpcall`.
2. `tokenizer` reads the file with `io` in 4096-byte chunks and produces tokens one at a time: start tag, end tag, text, comment, doctype. It is built on plain `string.find` and `string.byte`. It never runs `gsub` or `gmatch` over large strings (measured: `gsub` 94 KB/s, plain `find` 6338 KB/s).
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
- Comments, doctype, CDATA and processing instructions are skipped.
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
| `p div section article main header footer nav aside blockquote` | Block break |
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

### Text cleaning

`unicode.*` never throws on bad bytes. It turns them into U+FFFD and can count a wrong width. `utf8.len` accepts encoded surrogates. So the program cleans all text before any `unicode.*` call:

- Invalid sequences, truncated sequences, overlong forms and encoded surrogates (U+D800 to U+DFFF) become `?`.
- One `?` replaces each maximal invalid subpart (Unicode recommended practice). So an encoded surrogate gives 3 `?` (the game shows one U+FFFD).
- DEL 0x7F and the C1 controls U+0080 to U+009F are removed.
- The removed zero-width and invisible characters are U+00AD, U+200B, U+200C, U+200D, U+200E, U+200F and U+FEFF. (`unicode.wlen` counts U+200B as width 2.)
- Control bytes below 0x20 are removed, except tab and newline. `\r` is removed.
- Decoded entities pass through the same rules.
- The tokenizer calls `entities.decode(text.clean(s))`. A partial UTF-8 sequence or entity at a chunk end is held back with `text.split_tail` and joined to the next chunk.

### Viewer

- The last screen row is a status line: page title (or file name), scroll position in percent, and a key hint.
- Keys: Up/Down one line, PgUp/PgDn one screen, Home/End to the start and end, `q` to quit.
- `q` shows a prompt: quit or cancel.
- On start, the viewer sets the resolution to `gpu.maxResolution()` if the current resolution is different. `--no-rescale` skips this.
- The viewer then reads the size with `gpu.getResolution()`.
- On every exit path, the viewer restores the resolution it found at start.
- Measured: t3 had 120x60 on a GPU with a 160x50 maximum. This was a user-set resolution.
- Colors depend on `gpu.getDepth()`. Depth 8 and 4 use colors for headings, links and emphasis, given as RGB values. Depth 1 uses plain text. Palette indices are not used.
- The viewer caches the current foreground and background. It calls `setForeground` and `setBackground` only on a change (measured: a call costs as much as a `fill`, also with the same color).
- Scrolling moves the screen content with `gpu.copy` and draws only the new rows. A jump (PgUp, PgDn, Home, End) redraws the screen.
- One `gpu.set` call draws one same-style piece of a line. A call costs the same for 1 or 160 characters.
- On exit (normal or error) the screen colors are restored and the cursor goes below the output.

### Limits and graceful failure

There are no fixed size caps. The program measures and stops before damage happens.

- `guard.tick()` is called in every loop of the tokenizer and layout. It measures time with `os.clock()`, which has sub-millisecond steps (`computer.uptime()` moves in 50 ms steps). It yields with `os.sleep(0)` when more than `YIELD_INTERVAL` (1 s) has passed since the last yield. This is well below the 5 second OpenOS timeout. `guard.reset()` restarts the yield timer, and the tests use it. `guard.settled_free()` is public. It yields a few times and returns the highest `freeMemory()` reading.
- `guard.tick()` also checks `computer.freeMemory()` against `MEMORY_RESERVE` (128 KB). A reading can be up to about 200 KB too low, because garbage is not collected yet. Below the reserve, the guard yields a few times, reads `freeMemory()` again and uses the highest reading. Only when that reading is still below the reserve does it raise the controlled error "html: page too large for available memory (rendered N lines before stopping)".
- The program never calls `collectgarbage`. OpenComputers removes it on purpose.
- Before parsing, `bin/html.lua` compares the file size with free memory. If the file clearly cannot fit, it stops before reading.
- Controlled errors are strings with the prefix `html: `, raised with `error("html: <reason>", 0)`. `bin/html.lua` prints such a message as it is. Any other error value is unexpected: `bin/html.lua` prints one line and writes the full traceback to `/tmp/html-error.log`. This design does not depend on how error tables pass through `pcall` and `xpcall` (see `docs/probe/FACTS.md`, run t3), This is simpler than error tables.
- `/tmp` is only 64 KB. `/tmp/html-error.log` is capped at 8 KB. When the log would grow past the cap, the oldest content is dropped and the newest is kept.
- `bin/html.lua` takes the traceback function as a parameter, because the test sandbox removes `debug`. In game it gets `debug.traceback`.
- Ctrl+C (interrupted) exits cleanly and restores the screen.

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
local MEMORY_RESERVE = 128 * 1024
-- freeMemory() can read up to about 200 KB low until garbage is collected.
local SETTLE_TRIES = 3

local last_yield = os.clock()

local function yield()
  os.sleep(0)
  last_yield = os.clock()
end

local function settled_free()
  local best = computer.freeMemory()
  for _ = 1, SETTLE_TRIES do
    yield()
    best = math.max(best, computer.freeMemory())
  end
  return best
end

function M.tick(lines)
  if os.clock() - last_yield > YIELD_INTERVAL then
    yield()
  end
  if computer.freeMemory() < MEMORY_RESERVE and settled_free() < MEMORY_RESERVE then
    error("html: page too large for available memory (rendered "
      .. lines .. " lines before stopping)", 0)
  end
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
- Corpus tests: each file in `tests/cases/` has an expected text output. Each file in `tests/real/` must render without an error and with more than zero lines.
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
