# Remote fetching

Source: `lib/html/fetch.lua`, dispatch in `bin/html.lua`. Index: `SPEC.md`. URL rules: `spec/url.md`.

Status: approved by the user on 2026-11-14 (roadmap item 1). Roadmap entry: `tasks/todo.md` item 1.

Goal: `html http://...` and `html https://...` fetch a page with the Internet Card and render it with the same pipeline, guards and viewer as a local file.

The response is streamed into the renderer. It is not saved to a cache file first. The decision log D1 to D6 (cited below as "decision Dn") is in `docs/rationale.md` "Remote fetching: decisions".

- The viewer status line shows the page title. Without a title, it shows the URL in place of the file name.

## Internet card API

Decision D1. The program uses the card component directly: `component.internet.request(url, nil, headers)`. It does not use the OpenOS `internet` library. Reasons: `docs/rationale.md` "Remote fetching: Internet card API".

Calls on the request handle (OpenComputers `InternetCard`). The values below are measured in game (netprobe v1, `docs/probe/FACTS.md` "Internet card (netprobe v1)"):
- The card methods and the handle methods are callable tables, not functions. `type(card.request)` is `"table"`. Code that tests `type(m) == "function"` finds nothing. `pcall(card.request, ...)` and a direct call work.
- `request(url, nil, headers)` costs one tick (50 ms). It returns a handle, or nil and a reason. The limit is 4 open connections: the 5th `request` returns nil and `too many open connections`. `close()` frees a slot. A second `close()` is safe.
- `finishConnect()`: true when connected, false while pending, or nil and a reason on failure. It stays false until the response headers arrive (10.3 s on a server that waits 10 s). A 4xx or 5xx status is a failure here (see "HTTP error statuses").
- `response()`: nil while the request is pending, and `code, message, headers` at once after `finishConnect()` returned true. It needs no `read` first. Before `finishConnect()` returns true it gives nil.
- `read(n)`: a string of up to `n` bytes, `""` when no data is ready yet, nil at the end, or nil and a reason on error. Each `read` costs one tick (50 ms). Data needs no yield. `""` comes at most once in a row. The first reads on two hosts gave 2048 bytes.
- `headers` maps a name to a list of strings, one entry per name. The names keep the case of the server (`Content-Type`, `content-length`). The program compares them without case.
- `close()`: frees the connection.

Request headers sent: `User-Agent: oc-html/<version>` and `Accept-Encoding: identity`. No other header. No request body. With no headers given, the card sends `Accept: */*`, `Host` and `User-Agent: opencomputers/1.12.68-GTNH`, and no `Accept-Encoding`. No measured response had a `Content-Encoding`.

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

- The card follows redirects of the same scheme itself (Java `HttpURLConnection`, measured: a chain of 3 redirects gave one 200 response with `hops=0`). The response has no final URL. The program cannot know where the page came from, so the status line shows the URL that `fetch.open` knows: the URL it requested last. After a card-followed redirect that is the first URL (`redirects` is 0 and `final_url` equals the requested URL). Relative links resolve against that URL (`spec/url.md` "Link resolution"). Known limit: after a same-scheme redirect that the card follows, the final URL is unknown, so a relative link can resolve against the requested URL, which is wrong when the redirect changed the directory.
- A `<base href>` of the page, when present, replaces that URL as the base (`spec/url.md` "Base").
- One handle is open at most at any time. A navigation load closes its handle on every phase 1 failure and at every end of load (`spec/navigation.md` "During a load").
- A change of scheme (http to https or back) is not followed by the card. It gives a 302 with an absolute `Location` and an empty body. The rules below apply to that case.
- When `response()` gives 301, 302, 303, 307 or 308 with a `Location` header, `fetch.open` closes the handle and requests the new URL.
- `Location` can be an absolute `http(s)://` URL or a path that starts with `/` (joined to the current scheme, host and port). Any other form stops with `html: cannot follow redirect: <location>`.
- At most 5 redirects. The 6th stops with `html: too many redirects: <url>`.
- A redirect to a scheme other than http or https stops with `html: unsupported URL scheme: <scheme>`.
- The status line shows the final URL that the program knows (see the first point above).

## HTTP status and content type

- 200 to 299: the body renders.
- 300 to 399 without `Location`, and every status from 400 (an error status): the body renders too (decision D2). The program does not stop.
  - The viewer status line shows `[HTTP <code>]` before the title (or the URL).
  - `--print` writes one line `html: HTTP <code> <message>: <url>` to stderr before the page text. Stdout gets only the page text.
  - The exit code is 0, in the viewer and in `--print` mode (decision D6).
- Short page. For an error status, the program renders a short generated page in place of the body when:
  - the body is empty,
  - the first `read` fails, or the read times out before the first byte,
  - the content type is not one of the accepted types below.
  The short page is the document `<title><message></title><h1>HTTP <code> <message></h1><p><url></p>`. The title is the phrase only, because the status line has `[HTTP <code>]` already. With an empty message there is no `<title>`. It goes through the same tokenizer and layout.
  - In the message and the URL, `&` becomes `&amp;` and `<` becomes `&lt;`, so they show as written.
  - With an empty message, the text is `HTTP <code>`, without a trailing space.
- Error status with a body that breaks off. A read error or a read timeout after the first byte makes a broken page, like a 2xx body: no part renders. The viewer shows the popup over an empty page (`spec/loading.md` "Errors after the frame"). Print mode and the no-screen path print only the error line on stderr, and the exit code is 1. The `html: HTTP <code> <message>: <url>` notice prints only when the page is complete.
- The card gives no error body (N10, measured). See "HTTP error statuses". The rules above for a readable error body stay for a card that gives one. Their tests are marked "not seen in game".
- `Content-Type` with any `text/*` type (for example `text/html` or `text/plain`), `application/xhtml+xml`, or no `Content-Type`: the body renders (user decision, 2026-11-15). It goes through the same pipeline; at worst it shows as bare text, and a stray `<` in it renders as text or as an unknown tag.
  - The media type is compared without case. Parameters after `;` and spaces around the type are ignored. An empty `Content-Type` counts as no `Content-Type`.
- Any other type with a 2xx status stops before the body with `html: not an HTML page: <type>`. This covers binary types: images, archives and `application/*` other than XHTML. Downloads come with roadmap item 4.

## HTTP error statuses

Measured in game (N10, netprobe v1): for a 4xx or 5xx status, `request()` gives a handle, and `finishConnect()` returns nil and a reason. `response()` and `read()` are never reached, and no error body can be read. The reason holds the status (the Java `HttpURLConnection` message):

- 404: the reason is exactly the requested URL (a `FileNotFoundException` message).
- Other codes: `Server returned HTTP response code: <N> for URL: <url>` (seen for 500 and 403).

Decision (user, 2026-11-15). `fetch.open` maps the failure back to a status:
1. After a `finishConnect` failure it tries `pcall(h.response)`. When that gives a number from 400 to 599, it is the code. This is not proven in game (netprobe v1 never called `response()` after a failure; the probe now records it).
2. A reason equal to the requested URL means 404. A reason that starts with `Server returned HTTP response code: <N> for URL: ` means N, for N from 400 to 599. This is the main path.
3. Any other reason stays a connection error: `html: cannot connect: <url>: <reason>`. This includes unknown host, `Connection reset`, a TLS failure, a reason that only contains the URL, and a code outside 400 to 599.

A mapped status gives a response, not an error. `fetch.open` closes the handle and returns a response with `status`, `is_error`, the short page as its body (see above), `popup` and `notice`:
- The reason phrase comes from a table in `fetch.lua`: 400 Bad Request, 401 Unauthorized, 403 Forbidden, 404 Not Found, 405 Method Not Allowed, 408 Request Timeout, 410 Gone, 429 Too Many Requests, 500 Internal Server Error, 501 Not Implemented, 502 Bad Gateway, 503 Service Unavailable, 504 Gateway Timeout. Another code has no phrase.
- `popup` has two lines: `[HTTP <code>] <phrase>` (for example `[HTTP 404] Not Found`), or `[HTTP <code>]` with no phrase, then the URL. The viewer shows the short page and this popup with an `[OK]` button. The status line shows `[HTTP <code>] <phrase>` and does not repeat the code. The exit code is 0 when the user quits.
- `notice` is `html: HTTP <code> <phrase>: <url>` (no phrase: `html: HTTP <code>: <url>`). Print mode and the no-screen path print the short page, then this line on stderr, and exit with 0 (decision D6).

## Errors

All errors are controlled. Each is one line with the prefix `html: `, exit code 1, unless noted.

`fetch.open` returns nil, the message and a third value `retry`. `retry` is true when a retry may help: a `finishConnect` failure that is not a mapped HTTP status, a `response()` error, a connect timeout, a response timeout, and a failed `card.request` (`too many open connections`). The viewer shows `Reload to try again.` for these (`spec/navigation.md` "Retry line"). `retry` is false for every other error: not an HTML page, compressed response, no internet card, HTTP disabled, and the redirect errors.

| Case | Message |
|---|---|
| No internet card | `html: no internet card found (needed for <url>)` |
| HTTP disabled in the server config (`isHttpEnabled()` is false) | `html: HTTP requests are disabled on this server` |
| `request` raises or returns nil (bad address, blocked range, `too many open connections`) | `html: cannot fetch <url>: <reason>` |
| `finishConnect` fails (unknown host, `Connection reset`, TLS error) and the reason is not an HTTP status | `html: cannot connect: <url>: <reason>` |
| Connect or first response takes longer than `CONNECT_TIMEOUT` | `html: timed out connecting to <url>` |
| No new data for `READ_TIMEOUT` | `html: timed out reading <url> (<bytes> bytes received)` |
| `read` returns nil and a reason (any status, after the first byte) | `html: read error: <reason>` |
| Content type (2xx status): not `text/*`, not XHTML | `html: not an HTML page: <type>` |
| Ctrl+C | `html: interrupted`, exit code 130 |

- Measured failure texts: `unknown host: <host>: Name or service not known`, `Connection reset`, and `(certificate_expired) PKIX path validation failed: ...`.
- In the viewer, every error of this table that happens after the frame opened shows as a popup, and the session stays (`spec/loading.md` "Errors after the frame"). Print mode, the no-screen path and the errors before the frame print the line on stderr and exit with the code above.
- An error status (4xx, 5xx, or 3xx without `Location`) is not in this table. It renders (see "HTTP status and content type"). Its stderr line `html: HTTP <code> <message>: <url>` is a notice, not an error.
- For a guessed URL, each message ends with ` (no local file named <arg>)` (see `spec/url.md` "Arguments without a scheme").
- A reason from the card can be a string or another value. The message uses `tostring`, and the existing `reason()` helper in `bin/html.lua` cleans it.
- A raised error from a card call is caught with `pcall` in `fetch.lua` and turned into the matching message. No card error reaches the unexpected-error path.

## Timeouts and yields

- `CONNECT_TIMEOUT` is 15 s. It covers `finishConnect` and the wait for `response()`. Because `finishConnect` stays false until the response headers arrive (measured), it also bounds the time to the first header of a slow server. The card has no connect timeout of its own: a silent host was still pending after 20 s.
- `READ_TIMEOUT` is 30 s without any new byte. Each received chunk restarts it.
- Wall time comes from `computer.uptime()` (50 ms steps are enough here).
- Every wait loop calls `sleep(WAIT_STEP)`, so the program yields well inside the 5 s OpenOS limit. The loop also checks the interrupt flag, so Ctrl+C works during a slow server.
- Every `request()` and every `read()` costs one tick (50 ms), so a loop of reads is slow even when data is ready. The timeouts are still first guesses. The second netprobe run (large reads, memory) decides them.

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

Stats for a URL come from the probe: `spec/probe.md` "Keys".

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
- Note 7: The User-Agent version is the constant `VERSION` in `lib/html/fetch.lua` (now `0.4.0a`). Update it before each release.
- Note 8: Windows-1252 bytes with no character (0x81, 0x8D, 0x8F, 0x90, 0x9D) become the C1 code point. Text cleaning then removes them.
- Note 9: For a guessed URL, the suffix ` (no local file named <arg>)` is also on the deferred read-error line of an error status. It is not on `html: interrupted` (the exit code stays 130) and not on the `html: HTTP <code>` notice.
- Note 10: The interrupt flag is checked in each wait loop (connect, response, a `""` read). While data arrives, `guard.tick()` checks it per token.
- Note 11: `html.fetch` loads only for a URL, after the TUI opens. `html.url` loads during the argument checks, for a URL or a missing local file. A load failure gives `html: cannot load html.fetch: <reason>` (or `html.url`), exit code 1.
- Note 12: When `deps.exists` is not given (tests only), an argument without a scheme is always local (`spec/url.md`).

## In-game measurements and probe plan

The measurements N1 to N15 and the plan for `tools/netprobe.lua`: `docs/netprobe-plan.md`. The results of netprobe v1: `docs/probe/FACTS.md` "Internet card (netprobe v1)" and `docs/rationale.md` "Remote fetching: measurements (netprobe v1)".

## Open questions

None. Q1 to Q6 are decided (D1 to D6, `docs/rationale.md`).
