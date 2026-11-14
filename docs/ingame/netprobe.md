# In-game check: netprobe

Goal: measure the internet card facts N1 to N15 (`docs/netprobe-plan.md`) that
`lib/html/fetch.lua` assumes. Everything goes into one file, `netprobe.txt`.

Needs: an Internet Card, and a server that allows web requests. The probe
reads about 1 MB from the network (the large page), plus a few small pages.
It needs no installed `html`.

`<BASE>` is the raw URL of the repository source (the folder that holds
`tools/` and `tests/`).

## 1. Fetch the probe

```
wget -f <BASE>/tools/netprobe.lua /home/netprobe.lua
```

The probe fetches `<BASE>/tests/pages/large.html` (the large page, about
1 MB) and `<BASE>/AGENTS.md`, and a missing file under `<BASE>` for the 404
test. The default `<BASE>` inside the probe is
`https://raw.githubusercontent.com/RainVaporeon/oc-html/main`. If the
repository is elsewhere, pass `--base <BASE>` (step 2).

## 2. Run the probe

```
/home/netprobe.lua
```

Options:

```
/home/netprobe.lua --out <path>       report file (default: /home/netprobe.txt)
/home/netprobe.lua --base <url>       raw URL of the repository files (no trailing slash needed)
/home/netprobe.lua --echo <url>       echo service (default: https://httpbingo.org)
/home/netprobe.lua --skip-large       skip the large page section
/home/netprobe.lua --leak             see "Leak test" below
/home/netprobe.lua <url> [<url> ...]  measure these pages in place of the default small pages
/home/netprobe.lua --help
```

- The echo service must have `/status/<code>`, `/redirect-to?url=`,
  `/redirect/<n>`, `/delay/<n>`, `/headers` and `/user-agent`, on http and
  https (`httpbingo.org` and `httpbin.org` have them).
- Default small pages: `http://example.com/`, `https://example.com/` and
  `<BASE>/AGENTS.md`. Own URLs replace them.
- The probe prints one line per section (`netprobe: [1/9] api` to
  `netprobe: [9/9] limit`) and one line per request.
- It takes about 2 to 6 minutes. The waits are the largest part: the large
  page, a host that never answers (20 s), a slow server (10 s) and blocked
  addresses (8 s each).
- Each request has a timeout. A failed step is written as a value
  (`net.<section>.<name>.error=...`) and the probe goes on.
- Press Ctrl+C to stop it early (for example for N8, see below). The probe
  closes the open handle, still writes the report with
  `net.probe.interrupted=true` and `net.probe.interrupted_at=<section.step>`,
  and exits with code 130.
- The probe holds no page in memory. It counts bytes and keeps at most 256
  bytes of a body (2 KB of an echo answer). It writes to the report after each
  section.
- The `limit` section runs last. It opens requests until the card refuses
  one, and closes all of them.

## 3. N8, the manual step

N8 is Ctrl+C while a wait loop runs and while a slow server sends. Run the
probe a second time and press Ctrl+C once in each of these cases:

1. While it waits for a host that never answers: when the screen shows
   `netprobe:   silent http://example.com:81/`.
2. While it reads the large page: when the screen shows
   `netprobe:   page https://...large.html`.

For each case, note how long the stop took (the time between the key and
the prompt) and give the `net.probe.interrupted_at` line of that report. Use
`--out /home/netprobe-ctrlc.txt` so the first report stays.

## 4. Leak test (N13, optional)

N13 asks whether a program that exits without `close()` keeps its slot.

1. Reboot the computer. Run `/home/netprobe.lua --leak --out /home/leak1.txt`.
   At the end of the limit section it drops its handles without `close()`,
   collects garbage and records how many requests then work
   (`net.limit.leak.after_gc_opened`). It leaves those handles open and exits.
2. Without a reboot, run `/home/netprobe.lua --out /home/leak2.txt`. Compare
   `net.limit.opened` in both reports. A lower number in the second run means
   the slots stayed used after the exit.
3. Reboot the computer afterwards. The slots are free again.

## 5. Return the output

Copy `/home/netprobe.txt` to `./datacollection/` in the repository (the
probe prints this as its last line). If the probe stops with an error, also
paste the error text exactly as shown.

## What the probe writes

The file starts with `#netprobe v1`. Each line is `net.<section>.<name>=<value>`.
A step that failed writes `net.<section>.<name>.error=<reason>`. The last
lines are `net.probe.errors` and `net.probe.duration_ms`. Time values use
`computer.uptime` (50 ms steps), so a short time shows as 0 or a multiple of
50. CPU times use `os.clock`.

| Section | Fact | What it records |
|---|---|---|
| `api` | N1 | card fields, `component.methods`, `isHttpEnabled`, handle fields and methods, the type and the names of the `headers` table from `response()` |
| `connect` | N2, N3 | `finishConnect` polls and time, per page, twice; whether `response()` has a value before `finishConnect`, before the first `read`, or only after a read (`n3.*`) |
| `read` | N4, N5, N6 | chunk sizes and counts of `""` for `read()`, `read(4096)`, `read(65536)`; time to the first byte; call times (wall and CPU); a no-yield read loop (`spin.*`); free memory before, after connect, after a 1 s hold, after 16 chunks, minimum, after close |
| `large` | N7 | the whole large page: bytes, time, lowest free memory |
| `redirect` | N9 | the status and `Location` of http to http, http to https, https to http, and a chain of 3; a 3xx answer is followed by hand, hop by hop |
| `status` | N10 | 404 and 500: `finishConnect`, `response()`, `read`, the error body size and a sample |
| `fail` | N11, N12 | unknown host, refused port, a silent host, a TLS error, a slow server, `localhost`, `127.0.0.1` and two private addresses: which call fails, the text and the time |
| `headers` | N14, N15 | the request headers an echo server sees (default and custom); `Content-Length` and `Content-Type` of the three real page origins |
| `limit` | N13 | the number of open requests before a failure, the message, whether `close()` frees a slot, a double `close()`, and the `--leak` results |

Every request records the same fields (`request.*`, `connect.*`,
`response.*`, `status.*`, `headers.*`, `read.*`, `body.sample`, `close.*`).

The probe makes no other changes. It writes only the report file.
