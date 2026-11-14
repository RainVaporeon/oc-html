# Remote fetching

Source: `lib/html/fetch.lua`, dispatch in `bin/html.lua`. Index: `SPEC.md`. URL rules: `spec/url.md`.

Status: approved by the user on 2026-11-14 (roadmap item 1). Roadmap entry: `tasks/todo.md` item 1.

Goal: `html http://...` and `html https://...` fetch a page with the Internet Card and render it with the same pipeline, guards and viewer as a local file.

The response is streamed into the renderer. It is not saved to a cache file first. The decision log D1 to D6 (cited below as "decision Dn") is in `docs/rationale.md` "Remote fetching: decisions".

- The viewer status line shows the page title. Without a title, it shows the URL in place of the file name.

## Internet card API

Decision D1. The program uses the card component directly: `component.internet.request(url, nil, headers)`. It does not use the OpenOS `internet` library. Reasons: `docs/rationale.md` "Remote fetching: Internet card API".

Calls on the request handle (OpenComputers `InternetCard`):
- `finishConnect()`: true when connected, false while pending, or nil and a reason (or an error) on failure.
- `response()`: nil until the status line is in, then `code, message, headers`. `headers` maps a name to a list of values.
- `read(n)`: a string of up to `n` bytes, `""` when no data is ready yet, nil at the end, or nil and a reason on error.
- `close()`: frees the connection. The card has a limit of open connections (server config `internet.maxConnections`).

Request headers sent: `User-Agent: oc-html/<version>` and `Accept-Encoding: identity`. No other header. No request body.

- Response header names are not case-sensitive (`content-length`, `CONTENT-TYPE`).

`lib/html/fetch.lua` takes the card proxy, a clock, a sleep function and an interrupt check as parameters. It never calls `require("component")`. `bin/html.lua` passes the real links through `deps` (`deps.internet`, `deps.sleep`), so the tests can pass fakes.

## Stream into the pipeline

1. `bin/html.lua` parses the URL and opens the request with `fetch.open(url, links)`.
2. `fetch.open` waits for `finishConnect()` and then for `response()`. It follows redirects, records the status and checks the content type (see below).
3. It returns a response object with `read()`, `close()`, `status`, `length` (from `Content-Length`, or nil), `content_type` and `final_url`.
4. `bin/html.lua` passes `response.read` to `M.render(read, width)` in place of the file reader. The tokenizer, the layout and their guards do not change.
5. `response.read()` calls `handle.read(CHUNK)` (4096 bytes, the same as a file). On `""` it waits (`sleep(WAIT_STEP)`, 0.05 s) and asks again. It returns the first non-empty chunk, or nil at the end. A nil with a reason raises `html: read error: <reason>` (see implementation note 1).
6. The tokenizer already joins split tags, entities and UTF-8 sequences across chunk ends. So a response chunk can end at any byte.
7. The TUI opens before the request, and the content draws while the response streams (see `spec/loading.md`). The whole response is read before scrolling starts. The handle closes when the render ends.

The handle closes on every exit path: normal end, controlled error, unexpected error, quit during load and Ctrl+C. `bin/html.lua` closes it in the same cleanup as the local file (`close_file`). A double close is safe.

## Redirects

- The card may follow some redirects itself (Java `HttpURLConnection`, same scheme only). This is not measured yet (N9, `docs/netprobe-plan.md`).
- When `response()` gives 301, 302, 303, 307 or 308 with a `Location` header, `fetch.open` closes the handle and requests the new URL.
- `Location` can be an absolute `http(s)://` URL or a path that starts with `/` (joined to the current scheme, host and port). Any other form stops with `html: cannot follow redirect: <location>`.
- At most 5 redirects. The 6th stops with `html: too many redirects: <url>`.
- A redirect to a scheme other than http or https stops with `html: unsupported URL scheme: <scheme>`.
- The status line and `--stats` show the final URL.

## HTTP status and content type

- 200 to 299: the body renders.
- 300 to 399 without `Location`, and every status from 400 (an error status): the body renders too (decision D2). The program does not stop.
  - The viewer status line shows `[HTTP <code>]` before the title (or the URL).
  - `--print` writes one line `html: HTTP <code> <message>: <url>` to stderr before the page text. Stdout gets only the page text.
  - `stats: http=<code>` holds the code, as for any status.
  - The exit code is 0, in the viewer and in `--print` mode (decision D6).
- Short page. For an error status, the program renders a short generated page in place of the body when:
  - the body is empty,
  - the first `read` fails, or the read times out before the first byte,
  - the content type is not one of the accepted types below.
  The short page is the document `<title>HTTP <code> <message></title><h1>HTTP <code> <message></h1><p><url></p>`. It goes through the same tokenizer and layout.
  - In the message and the URL, `&` becomes `&amp;` and `<` becomes `&lt;`, so they show as written.
  - With an empty message, the text is `HTTP <code>`, without a trailing space.
- Error status with a partial body. A read error or a read timeout after the first byte ends the body. The received part renders.
  - In the viewer, a popup reports the error line (`spec/viewer.md` "Error popup"). The user closes it and keeps browsing the partial page. The line is not printed on stderr after the exit. The exit code is 0 when the user quits normally.
  - In print mode or with no screen, the program prints the partial text and then the error line (`html: read error: <reason>` or the read timeout message) on stderr. The exit code is 0 (decision D6).
- The card may not give an error body at all (Java `HttpURLConnection` raises on 4xx and 5xx). N10 must confirm that the error body can be read. Until N10 is measured, the tests cover both cases: a readable body, and a card that fails the first `read`, which gives the short page. If `finishConnect` itself fails on an error status, no code is known, and the connect error applies.
- `Content-Type` `text/html`, `application/xhtml+xml`, `text/plain` or no `Content-Type`: the body renders. `text/plain` goes through the HTML tokenizer like any text; a stray `<` in it renders as text or as an unknown tag.
  - The media type is compared without case. Parameters after `;` and spaces around the type are ignored. An empty `Content-Type` counts as no `Content-Type`.
- Any other type with a 2xx status stops before the body with `html: not an HTML page: <type>`. Downloads come with roadmap item 4.

## Errors

All errors are controlled. Each is one line with the prefix `html: `, exit code 1, unless noted.

| Case | Message |
|---|---|
| No internet card | `html: no internet card found (needed for <url>)` |
| HTTP disabled in the server config (`isHttpEnabled()` is false) | `html: HTTP requests are disabled on this server` |
| `request` raises or returns nil (bad address, blocked range, too many connections) | `html: cannot fetch <url>: <reason>` |
| `finishConnect` fails (unknown host, refused, TLS error) | `html: cannot connect: <url>: <reason>` |
| Connect or first response takes longer than `CONNECT_TIMEOUT` | `html: timed out connecting to <url>` |
| No new data for `READ_TIMEOUT` | `html: timed out reading <url> (<bytes> bytes received)` |
| `read` returns nil and a reason (2xx status) | `html: read error: <reason>` |
| Content type (2xx status) | `html: not an HTML page: <type>` |
| Ctrl+C | `html: interrupted`, exit code 130 |

- An error status (4xx, 5xx, or 3xx without `Location`) is not in this table. It renders (see "HTTP status and content type"). Its stderr line `html: HTTP <code> <message>: <url>` is a notice, not an error.
- For a guessed URL, each message ends with ` (no local file named <arg>)` (see `spec/url.md` "Arguments without a scheme").
- A reason from the card can be a string or another value. The message uses `tostring`, and the existing `reason()` helper in `bin/html.lua` cleans it.
- A raised error from a card call is caught with `pcall` in `fetch.lua` and turned into the matching message. No card error reaches the unexpected-error path.
- With `--stats`, a fetch error prints the stats lines and `stats: stopped=<message>` (see `spec/stats.md`).

## Timeouts and yields

- `CONNECT_TIMEOUT` is 15 s. It covers `finishConnect` and the wait for `response()`.
- `READ_TIMEOUT` is 30 s without any new byte. Each received chunk restarts it.
- Wall time comes from `computer.uptime()` (50 ms steps are enough here).
- Every wait loop calls `sleep(WAIT_STEP)`, so the program yields well inside the 5 s OpenOS limit. The loop also checks the interrupt flag, so Ctrl+C works during a slow server.
- The values are first guesses. N2, N5 and N11 decide them.

## Charset

- The pipeline treats text as UTF-8. Text cleaning turns invalid bytes into `?`, so no charset can crash the render.
- Decision D3. The `charset` parameter of `Content-Type` is read. For `iso-8859-1`, `latin1` and `windows-1252` (the HTTP default for many old pages), `fetch.lua` converts each byte above 0x7F to UTF-8. Bytes 0x80 to 0x9F use the Windows-1252 table that `entities.lua` already has for numeric references. Bytes 0xA0 to 0xFF map to the same code point. The conversion runs per chunk; it needs no state, because each input byte is one character.
- Any other charset passes through as UTF-8. Non-ASCII text then shows as `?`.
- `<meta charset>` in the body is not read. It would need a look-ahead before the tokenizer starts.

## Compression (deferred)

- The program sends `Accept-Encoding: identity`, so a server sends plain bytes.
- A response with `Content-Encoding` other than `identity` stops with `html: compressed response not supported: <encoding>`.
- Data Card inflate stays a separate side item (`tasks/todo.md`). It needs N14 first.

## Memory

- The card keeps the network buffer outside the Lua heap (to confirm with N6). The Lua side holds one chunk of up to 4096 bytes at a time, as with a file.
- With `Content-Length`, the size check before reading applies unchanged (`spec/guard.md` "Size check before reading"): `length * SIZE_COST_MIN > settled free` stops with `html: page too large for available memory (<length> bytes, <free> free)` before the first body read.
- Without `Content-Length`, there is no check before reading. `guard.tick()` protects the render exactly as for a large local file: it settles and stops with `html: page too large for available memory (rendered N lines before stopping)`.
- A response that is longer than its `Content-Length` is read to its end. The guard still applies.
- These rules apply to an error body too.
- The wait loop sleeps, which also gives the kernel its 10th-resume GC. The guard needs no change.
- The handle closes when the load ends, before scrolling starts. So after the load, the viewer has the same memory as for a local file.

## Stats

The stats lines for a URL: `spec/stats.md` "Remote pages".

## Tests

All tests run in the container with `--network none`. No test touches a real network. The fetch tests and the expected results for arguments without a scheme are in `docs/testing.md` "Remote fetching".

## Implementation notes (2026-11-14)

The implementation chose the smallest change where a rule above was open or could not work as written:

- Note 1: `response.read()` does not raise. It returns a chunk, nil at the end, or nil and a full controlled message. `bin/html.lua` raises the message. Reason: `SPEC.md` "Code style" allows only `guard` to raise controlled errors.
- Note 2: A status outside 200 to 299 that is not a redirect with `Location` (for example 1xx or 304) is an error status. It renders like a 404.
- Note 3: For an error status, a `Content-Encoding` other than `identity` gives the short page. It does not stop. Reason: decision D2 says an error status never stops the program.
- Note 4: A `Location` that starts with `//` (scheme-relative) stops with `html: cannot follow redirect: <location>`. The rule "a path that starts with `/`" would join it as a path on the old host, which is wrong. An absolute `Location` that fails the URL parsing rules also gives this message. A `Location` with another scheme gives `html: unsupported URL scheme: <scheme>`.
- Note 5: `html: too many redirects: <url>` names the URL that the user gave (after the scheme guess), not the last redirect target.
- Note 6: `html: not an HTML page: <type>` shows the media type without parameters (for example `image/png`).
- Note 7: The User-Agent version is the constant `VERSION` in `lib/html/fetch.lua` (now `0.2.0a`). Update it before each release.
- Note 8: Windows-1252 bytes with no character (0x81, 0x8D, 0x8F, 0x90, 0x9D) become the C1 code point. Text cleaning then removes them.
- Note 9: For a guessed URL, the suffix ` (no local file named <arg>)` is also on the deferred read-error line of an error status. It is not on `html: interrupted` (the exit code stays 130) and not on the `html: HTTP <code>` notice.
- Note 10: The interrupt flag is checked in each wait loop (connect, response, a `""` read). While data arrives, `guard.tick()` checks it per token.
- Note 11: `html.fetch` loads only for a URL or a missing local file. A load failure gives `html: cannot load html.fetch: <reason>`, exit code 1.
- Note 12: When `deps.exists` is not given (tests only), an argument without a scheme is always local (`spec/url.md`).

## In-game measurements and probe plan

The measurements N1 to N15 and the plan for `tools/netprobe.lua`: `docs/netprobe-plan.md`.

## Open questions

None. Q1 to Q6 are decided (D1 to D6, `docs/rationale.md`).
