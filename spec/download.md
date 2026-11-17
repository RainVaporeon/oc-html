# Download

Source: `lib/html/download.lua` (the file name, the part file, streaming to disk), `bin/html.lua` (the Ctrl+S flow, the link to a file, the job), `lib/html/fetch.lua` (the `raw` and `file_ok` options), `lib/html/viewer.lua` (prompts). Index: `SPEC.md`. Fetching: `spec/fetch.md`. File writes: `spec/errors.md` "File writes". Reasons: `docs/rationale.md` "Downloads stream to a part file".

Status: roadmap item 0.7.0a, spec written, waiting for the user's approval. The user decided on 2026-11-17: the download prompt is plain text, and the default download folder is the working directory. The user revised the spec on 2026-11-17: Ctrl+S starts a download (not `d`), and a followed link to a file opens the save prompt.

Doc rules: Minecraft catches Esc in game, so the prompts do not use Esc. A blank Enter cancels each prompt.

## Key

- Ctrl+S starts a download. The key `d` is not a download key and stays free.
- Detection. OpenComputers sends Ctrl+S as a `key_down` with char 19 (0x13) on most clients. `classify` returns the action `download` for a `key_down` with char 19, or with key code 31 (S) while `keyboard.isControlDown()` is true. The viewer gets `isControlDown` as a dep, as `isShiftDown`. Without the dep, the viewer tracks `key_down` and `key_up` of the codes 29 and 157 (the Ctrl keys), as for Shift (`spec/viewer.md` "Link keys").
- Ctrl+S is checked after Ctrl+C (char 3), so it does not collide with it.
- The game may send char 19, or code 31 with a different char. The in-game check records which one the game sends (`tasks/todo.md` 0.7.0a, in-game checklist).

## Target

- Ctrl+S with a visible selected link downloads the link target.
- Ctrl+S with no visible selection downloads the URL of the current page. A broken or aborted page has a URL too. The program always fetches again, because the cache holds charset-converted bytes and not the raw bytes.
- Refused cases. Each one shows a status notice until the next key:
  - a local target: `Ctrl+S: only web files can be downloaded`
  - an unsupported scheme: `<scheme>: links are not supported`
  - a link stored as false: `link too long`
  - Ctrl+S during a page load: `wait for the load, or press z`
  - Ctrl+S during a download: `download running: z stops it`

## Prompt

- The status row shows ` Save to: <default path>`. The default path is plain text, and the input cursor (a reverse-video cell) is at the end of it.
- Printable ASCII 0x20 to 0x7E adds a character. Backspace deletes one character. A clipboard event adds its text.
- Enter accepts the text. A blank Enter cancels.
- The path accepts `~` (`M.expand_home`) and relative paths, which `shell.resolve` resolves against the working directory.
- When the path is an existing directory, the program adds the default file name to it.
- When the parent directory does not exist, the popup `html: no such directory: <dir>` shows.
- When the file exists, the status row shows ` Overwrite <name>? (y/n)`. Only `y` or `Y` overwrites. Enter and every other key cancel. Enter is not "yes" here, so a held Enter cannot overwrite a file.

## Default path

- The folder is the working directory, `shell.getWorkingDirectory()` (usually `/home`). This is what `wget` does.
- The file name comes from the `filename` parameter of the `Content-Disposition` header when the response has one and it gives a name (see "Link to a file"). Else it comes from the last segment of the URL path:
  1. Drop the query and the fragment.
  2. Decode each `%XX`.
  3. Replace each byte outside 0x20 to 0x7E, and each `/ \ : * ? " < > |`, with `_`.
  4. Cut the name to 64 bytes and keep the extension.
  5. An empty name, `.` or `..` becomes `index.html`.
- A `Content-Disposition` name takes only the steps 3 to 5, after the program drops everything up to the last `/` or `\`. It takes the `filename` parameter (quoted or not, compared without case). It ignores `filename*`. When the cleaned name is empty, the name comes from the URL.

## Link to a file

A followed link can lead to a file. Then the program opens the save prompt and does not show an error.

- Which navigations. Enter on a link, `t` (with a link or with the prompt text) and the `g` prompt text, to an `http://` or `https://` target. These are the load modes `link` and `go`. The load of `t` runs as a `link` load until its commit (`spec/tabs.md` "Behavior"). Other loads keep today's rule: the start argument, `--print`, `r`, Back, Forward, a tab switch and a pending load of a history entry give `html: not an HTML page: <type>`, because such an entry was a page once.
- A file download is a response with a 2xx status and one of:
  - a content type that the viewer does not render (any type outside the accepted types of `spec/fetch.md` "HTTP status and content type": `text/*`, `application/xhtml+xml`, or no type), or
  - the header `Content-Disposition` with the disposition type `attachment` (compared without case), also with an accepted type.
  An error status keeps its short page. A `Content-Encoding` other than `identity` keeps `html: compressed response not supported: <encoding>`.
- The load gives the response to the session loop and does not read the body. The program keeps this open response and does not fetch again. `fetch.open` takes the option `file_ok = true` for these loads and gives the response `is_file = true` and `filename` (`spec/fetch.md` "HTTP status and content type").
- The default file name comes from `Content-Disposition` when it exists, else from the URL: the final URL of the response, after the redirects ("Default path").
- The navigation does not change the history and does not change the current page. The current page, `top`, `sel` and the history stay as they were. The current page stays on screen during the prompt and the download. No history entry is pushed. The load starts no cache writer, and nothing is cached.
  - With `t`, no tab opens, because the new tab opens only at the commit of a page. The prompt opens over the current page, and the current tab does not load again.
- The save prompt then shows (` Save to: <default path>`, "Prompt"). It opens at once, with the response still open.
  - A blank Enter cancels. The response handle closes. The page and the status line are as before.
  - Ctrl+C at the prompt closes the handle and exits with code 130.
  - An accepted path starts a normal download job with this response (`bg` slot). It has the same progress, keys, end notices and errors as a download that Ctrl+S starts ("Progress, keys and end"). The overwrite prompt, the directory checks and the disk-space checks apply. An answer of "no" at ` Overwrite <name>? (y/n)`, and each other cancel, closes the handle.
- Timeout rule. The response stays open while the prompts show, so the card read timeout must not count the prompt time. `READ_TIMEOUT` of a kept response starts at its first `read()` call, not when `fetch.open` returned (`spec/fetch.md` "Timeouts and yields"). `CONNECT_TIMEOUT` ended at the open. A server can still close the idle connection. Then the first read gives a read error, and the usual download error popup shows (the part file is deleted).
- The card allows 4 open connections. The kept response is the one open connection: at most one load, one download or one kept response is open at any time.
- A followed link while a download job runs shows the notice `download running: z stops it` and opens nothing ("Progress, keys and end").

## Content and transfer

- A download saves the raw response bytes. It does not render the page or convert the charset. A download that Ctrl+S starts fetches again: `fetch.open` gets the option `raw = true` (`spec/fetch.md` "HTTP status and content type"). With it, every content type is accepted and the Latin-1 step is skipped.
- The error `html: compressed response not supported: ...` stays. The card does not inflate, so the saved bytes would be wrong.
- Redirects work as they do for a page.
- The download writes to `<path>.part`. A `<path>.part` that exists already is replaced.
- Each chunk (at most 4096 bytes; the card gives 2048) goes to the file at once. Nothing collects in memory, so the memory use stays flat for any file size.
- The download is a coroutine job in the `bg` slot, and the viewer loop drives it. It uses the `wait` and `slice` yields of a load (a slice is about 0.1 s) and never calls `os.sleep` (`spec/loading.md` "Keys during load").
- At the end, the program checks the results of `write`, `flush` and `close` with the rules of `M.write_text` (`spec/errors.md` "File writes"): a `close` with no return values is a success. Then it renames `<path>.part` to `<path>`. A rename over an existing file replaces it (measured).
- A download does not read or write the page cache.
- `lib/html/download.lua` makes no `component` calls. The links for the card, the filesystem and the yields come from `deps`. `game_deps` gets `space`, `remove`, `rename` and `cwd`.

## Disk space

- Free space = `spaceTotal() - spaceUsed()` of `filesystem.get(path)`. The program always keeps a reserve of 64 KB free, the same reserve as the cache (`spec/cache.md` "Budget").
- With `Content-Length`: when the length is more than the free space minus the reserve, the program stops before the first read. It closes the handle and shows `html: not enough disk space: <n> KB needed, <m> KB free`.
- Without `Content-Length`: the program checks the free space after each 64 KB that it writes. Below the reserve it stops with the same message (`<n>` is the bytes so far).
- A full disk can show only at `flush` or `close` (measured on tmpfs). That error also deletes the part file.
- A read-only filesystem gives `html: cannot write <path>: read-only filesystem`.

## Progress, keys and end

- Status line, with a rate limit of one update each 0.25 s:
  - First the phase texts of `spec/loading.md` (`Connecting to <host>...`, `Waiting for response...`, `Redirect to <url>...`).
  - Then `Downloading <name> - <n> KB of <m> KB`, or `Downloading <name> - <n> KB` without `Content-Length`.
  - The `[i/n] ` prefix of `spec/tabs.md` stays in front.
- Keys during a download:
  - Scroll keys, Tab, Shift+Tab, Up, Down and `?` work.
  - `z` stops the download.
  - Enter on a link, Back, Forward, Left, Backspace, `r`, `g`, `t`, `c`, `<`, `>`, `!` and Ctrl+S show the notice `download running: z stops it` and do nothing else. Backspace and Left do not stop a download, because a long download must not stop by accident.
  - `q` shows the quit prompt, and the download goes on while it shows. A confirmed quit stops the download and deletes the part file.
  - Ctrl+C stops the download, deletes the part file and exits with code 130.
- Success: the notice `Saved <path> (<n> KB)` shows until the next key.
- A stop with `z`: the notice `download stopped` shows. No file and no part file remain. The program closes the response at once, also when it came from a followed link, so a slow server does not hold the stop.
- Errors show a popup with `[OK]` and no reload line. Each error deletes the part file and keeps an existing target file:
  - every `fetch.open` error (connect, timeout, `too many open connections`, no card, HTTP disabled, redirect errors)
  - `[HTTP <code>] <phrase>` and the URL. The card gives no error body, so nothing is saved.
  - `html: compressed response not supported: <encoding>`
  - `html: cannot write <path>: <reason>`
  - `html: no such directory: <dir>`
  - `html: not enough disk space: <n> KB needed, <m> KB free`
  - `html: timed out reading <url> (<n> bytes received)`
- A crash can leave `<path>.part`. This is accepted and documented.

## Messages

| Text | Kind |
|---|---|
| ` Save to: ` | prompt |
| ` Overwrite <name>? (y/n)` | prompt |
| `Ctrl+S: only web files can be downloaded` | notice |
| `wait for the load, or press z` | notice |
| `download running: z stops it` | notice |
| `Downloading <name> - <n> KB of <m> KB` / `Downloading <name> - <n> KB` | status |
| `Saved <path> (<n> KB)` | notice |
| `download stopped` | notice |
| `html: no such directory: <dir>` | popup |
| `html: not enough disk space: <n> KB needed, <m> KB free` | popup |
| `html: cannot write <path>: <reason>` | popup |

The full list of the messages of 0.7.0a is in `spec/errors.md` "Tab, shell and download messages".
