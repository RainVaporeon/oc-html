# Test coverage

Moved from `SPEC.md` "Testing Strategy" and from `SPEC.md` "Remote fetching", section "Tests". The rules for the test environment (Docker, shims, sandbox, no network) are in `spec/testing.md`.

## Local rendering (from "Testing Strategy")

- The runner helper `t.load_bin(name)` loads `bin/<name>.lua` as a text chunk in the same sandbox env. `bin/html.lua` returns its module table when its first argument is a table, so tests can call `M.main(argv, deps)`.
- Unit tests: tokenizer (each parsing rule), entities, layout (each row of the element table, wrapping, whitespace).
- Module cache tests use a fake `package.loaded` table: `M.clear_modules`, the chunk load with a fake global `package`, and `M.run_program` on a normal exit and on an error.
- memprobe tests: `tools/memprobe.lua` with fake machine links (step 1 and 2, reboot, failed allocation, errors, Ctrl+C, write failure).
- netprobe tests: `tools/netprobe.lua` with the fake card (report format, one failing step, Ctrl+C, write failure, arguments, the N facts per fake script).
- Installer tests: the template with a fake filesystem (install, upgrade, dry run, short space, read-only, write, read-back and rename failures), the long-bracket encoder, and every `releases/*/html-install.lua` against its release files (skipped while no release has one).
- Corpus tests: each file in `tests/cases/` has an expected text output. Each file in `tests/real/` must render without an error and with more than zero lines.
- Large page: `tests/pages/large.html` renders at width 160 with no uncontrolled error. The test prints its size, line count and CPU time. To make the page again: `docker run ... oc-html-test lua5.3 tools/genpage.lua > tests/pages/large.html` (same flags as `test.ps1`). The fixed seed gives the same bytes.
- Fuzz tests: `tests/fuzz.lua` generates random tag soup and mutates files from the corpus (cuts, duplicated tags, random bytes). Every document must finish with lines or a controlled error. Any other error fails the run and saves the input to `tests/fuzz-failures/`.
- In-game checks (manual, on a depth-8, a depth-4 and a depth-1 screen): the real-world pages, scrolling, quit prompt, resume, the low-memory error and the screen restore after an error.

## Remote fetching (from "Remote fetching", section "Tests")

- `tests/shim/internet.lua`: a fake card. A script describes each request: connect polls before success or an error, `response()` polls, code, message and headers, the list of body chunks with `""` gaps, a mid-stream error, a never-ending body, and a raised error from `request`. The fake records `close()` calls and the open count, and enforces a connection limit.
- `tests/fetch_test.lua`: URL parsing (every rule in `spec/url.md`), `looks_like_host` (the list below), redirects (absolute, path, chain of 5, 6th fails, other scheme, missing `Location`), content-type rules, charset conversion, `Content-Encoding` refusal, both timeouts with a fake clock, interrupt during connect and read, and one `close()` per request on every path.
- Error status: a 404 and a 500 with an HTML body render it. An empty body, a first `read` that fails, a read timeout before the first byte and a non-HTML type each give the short page. A read error after some bytes renders the received part and prints the read error after the output. A 3xx without `Location` renders like a 404.
- `tests/entry_test.lua`: URL arguments with all options, no card, HTTP disabled, the size check with `Content-Length`, exit codes 1, 2 and 130. For an error status: the `[HTTP <code>]` prefix in the viewer title, the stderr line in `--print` mode, and exit code 0.
- Arguments without a scheme (`deps.exists` is a fake). Expected results:

| Argument | Local path exists | Result |
|---|---|---|
| `./x.html` | yes | local file |
| `./x.html` | no | `html: file not found: ./x.html` |
| `x.html` | yes | local file |
| `x.html` | no | `html: file not found: x.html` (extension rule) |
| `dir/x.html` | no | `html: file not found` (no dot in the host part) |
| `dir/example.com` | no | `html: file not found` |
| `example.com` | yes | local file |
| `example.com` | no | `http://example.com` |
| `EXAMPLE.COM` | no | `http://EXAMPLE.COM` |
| `example.com/path` | no | `http://example.com/path` |
| `example.com/` | no | `http://example.com/` |
| `example.com:8080/a?b=1` | no | `http://example.com:8080/a?b=1` |
| `example.com#top` | no | `http://example.com`, fragment removed |
| `localhost` | no | `http://localhost` |
| `localhost:8080` | no | `http://localhost:8080` |
| `192.168.0.1` | no | `http://192.168.0.1` |
| `foo` | no | `html: file not found` (one label) |
| `foo:8080` | no | `html: file not found` (one label, not `localhost`) |
| `example..com` | no | `html: file not found` (empty label) |
| `a.-b.com` | no | `html: file not found` (label starts with `-`) |
| `example.com:`, `example.com:0`, `example.com:99999` | no | `html: file not found` (bad port) |
| `exa mple.com` | no | `html: file not found` (space) |
| a host with a byte above 0x7E | no | `html: file not found` (no IDN support) |
| `~/example.com` | no | `html: file not found` |
| `ftp://example.com` | (not checked) | `html: unsupported URL scheme: ftp`, exit code 2 |

- A guessed URL with a failing fetch: the message ends with ` (no local file named <arg>)`.
- Corpus: each `tests/cases/*.html` is served by the fake card in chunks of 1, 7, 4096 and 65536 bytes, with `""` gaps. The output must equal the `.txt` file. Each `tests/real/` page and `tests/pages/large.html` render through the fake card with no uncontrolled error.
- Fuzz: `tests/fuzz.lua` sends a share of its documents through the fake card, with random chunk sizes, random `""` gaps, random headers (status, type, charset, length) and random mid-stream errors. Every document ends with lines or a controlled error, and the handle is closed.
- Type stubs: `types/openos.lua` gets the internet component and the request handle.
