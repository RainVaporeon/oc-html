# Network probe plan (remote fetching)

Moved from `SPEC.md` "Remote fetching", sections "In-game measurements" and "Probe script plan". The rules of remote fetching are in `spec/fetch.md` and `spec/url.md`. The IDs N1 to N15 are used in `spec/fetch.md`, `spec/url.md`, `tasks/todo.md` and `docs/HANDOFF.md`.

## In-game measurements

Measure these before or during the implementation. Results go to `docs/probe/FACTS.md`. N1 to N6, N9 to N11 and N13 come first; they can change the design in `spec/fetch.md`.

| ID | Measurement | Decides |
|---|---|---|
| N1 | Methods of the internet component and the request handle; `isHttpEnabled()`; the type of `headers` from `response()` (name case, list values) | API section |
| N2 | Connect time: `finishConnect` polls and wall time, http and https, near and far host | `CONNECT_TIMEOUT` |
| N3 | When `response()` gives a value: before the first `read`, or only after it | wait order in `fetch.open` |
| N4 | Chunk sizes: `read()`, `read(4096)` and `read(65536)` on a large page. Size spread and the count of `""` results | `CHUNK`, `WAIT_STEP` |
| N5 | Time per `read` call and throughput in KB/s. Is a `read` a direct call or one that waits for the next tick? Longest single call | timeouts, expected fetch time |
| N6 | Memory per chunk: settled free memory before the request, after connect, after N chunks read and dropped. Does the card buffer outside the Lua heap? | "Memory" section |
| N7 | Large page: fetch the raw `tests/pages/large.html` (about 1 MB) and drop the chunks. Total bytes, wall time, lowest free memory | success criterion for remote pages |
| N8 | Ctrl+C while a wait loop runs and while a slow server sends | interrupt handling |
| N9 | Redirects: http to http, http to https, https to http, a chain of 3. The status that `response()` shows and the `Location` header | "Redirects" section |
| N10 | Status 404 and 500: what `finishConnect`, `response()` and `read` give. Is the error body readable? Required for decision D2: it confirms whether the error body renders or the short page shows | "HTTP status" section |
| N11 | Unreachable server: unknown host, refused port, an address that never answers. Which call fails, the message text and the time to fail. The server `internet.requestTimeout` behavior | error table, timeouts |
| N12 | Blocked address (`localhost`, a private range from the default blacklist): which call fails and the message | error table, the guessed `localhost` URL |
| N13 | Connection limit: open requests without `close()` until one fails. The message. Does `close()` free a slot? Does a program that exits without `close()` leak the slot? | close rules |
| N14 | Request headers as the server sees them (an echo endpoint): the default `User-Agent`, `Accept-Encoding`, and whether custom headers arrive | request headers, compression |
| N15 | `Content-Length` and `Content-Type` charset on the origins of the three `tests/real/` pages | memory check, charset |

The test URLs need a stable server. Use the repository raw files for large pages and a public echo service (status, redirect, delay and header-echo endpoints) for N9 to N14. The user picks the hosts.

## Probe script plan

The `tools/probe2.lua` pattern fits. A new `tools/netprobe.lua` (not part of a release, not written yet):

- Usage: `netprobe [--out <path>] [--base <url>] [--echo <url>] [--skip-large]`.
- Same output format as probe2: one `net.<group>.<name>=<value>` fact per line, one output file, long values split into numbered parts.
- It yields at least every 0.25 s and closes every handle it opens, also on an error and on Ctrl+C.
- Sections in order: `api` (N1), `connect` (N2, N3), `read` (N4, N5, N6), `large` (N7, skipped with `--skip-large`), `redirect` (N9), `status` (N10), `fail` (N11, N12), `limit` (N13, last, because it may leave slots open), `headers` (N14, N15). N8 is a manual step in a `docs/ingame/` checklist.
- Each failure inside a section is recorded as a fact (`net.<group>.<name>.error=<reason>`). The probe goes on with the next section.
- Tests: `tests/netprobe_test.lua` runs it against the fake card from `tests/shim/internet.lua`, like the memprobe tests.
