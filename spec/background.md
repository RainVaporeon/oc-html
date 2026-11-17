# Background loads (planned)

Source (planned): `bin/html.lua`, `lib/html/jobs.lua`, `lib/html/cache.lua`, `lib/html/fetch.lua`, `lib/html/guard.lua`, `lib/html/viewer.lua`. Index: `SPEC.md`. Tabs: `spec/tabs.md`. Shell: `spec/shell.md`. Cache: `spec/cache.md`.

Status: planned (0.7.1a). Not approved. It needs the probes P1 to P6 and the user's approval before code starts. It changes the stop rule of `spec/tabs.md` "A load at a tab switch or at `!`": when resources allow, a load that the user leaves goes on in the background and streams to disk. The `pending` rule for phase 1 stays. The user decided on 2026-11-17: the releases are split (0.7.0a has no background loads), background loads pause during the shell, and a resume without `ETag` or `Last-Modified` restarts from byte 0. In this file, "Part 1" means `spec/tabs.md`, `spec/shell.md` and `spec/download.md`.

## B.1 The split: stream to disk, no parse

- A background load writes the response bytes to its cache part file. It does not parse or render, so its memory stays flat, as for a download.
- When it ends, `commit_complete` makes a normal cache entry. When the tab shows again, it renders from that entry (the `switch` mode).
- Code check (0.6.0a): `cache.begin` gives a writer for 2xx remote pages. The loader's `read()` calls `writer.write(chunk)` with the charset-converted chunk before the tokenizer gets the chunk. So a background job can loop on `resp.read()` and `writer.write(chunk)` with no tokenizer and no layout, and the cache file format stays the same.
- Required change: today `b.cancel()` always closes the handle and aborts the writer. The loader gets a new exit, `b.detach()`. It ends the render and returns `{ resp, writer }` without closing them.
- "Detach" means to move a load to the background. A load can detach only after the commit, and only for a remote 2xx response that still has its cache writer.
- These loads cannot detach. They stop with the rules of `spec/tabs.md` "A load at a tab switch or at `!`":
  - local files and cache replays (no network, cheap to load again)
  - short HTTP-status pages
  - loads in phase 1 (no bytes yet). The tab keeps `pending`, as in 0.7.0a.

## B.2 Resource checks before a detach

The program checks the resources in this order. The first check that fails selects the fallback in B.3.

| Resource | Rule | Reason |
|---|---|---|
| Card connections | At most 2 background jobs. The foreground load or the download uses 1 more, so at most 3 of 4 are in use. | The card allows 4 open connections (netprobe v1). The spare one covers a redirect hop and programs in the tab-out shell. |
| Memory | `guard.settled_free()`, measured after the release of the old document, is at least 256 K. | The guard reserve (`MEMORY_RESERVE`) is 192 K. The extra 64 K covers 2 jobs of about 16 K each, plus margin. A raw `freeMemory()` reading is not reliable: it jitters by up to 213 K and can be up to 1.3 MB too low because of garbage (FACTS.md). A settle costs up to about 110 ms, once per switch. |
| Disk | With `Content-Length`: the length is at most the cache byte budget minus the bytes of all writers in flight. Without a length: the cap check of the writer applies while the job runs. | The cache budget is min(25% of free, 2 MiB, free − 64 K). A page over the cap is never cached, so it cannot load in the background. |
| CPU | No check. The jobs take turns (B.5). | A background job does only I/O. |

- During a job, the program checks the memory only at the settles of a foreground render. The jobs do not grow, so another check gives no new data.
- Memory estimate for one job: a 4 KB chunk is about 2.3 K scaled (×2 with garbage), the coroutine and tables are about 4 K, and the file buffer is small. Total: about 16 K scaled. Probe P6 measures it.

## B.3 Fallback order

The fallbacks, in this order:

1. **No parse.** A tab in the background never parses or renders. This rule is always active.
2. **All background slots in use at a detach.** The oldest background job is suspended (B.4). Then the new load detaches. The newest user action wins, and the bytes of the old job stay on disk.
3. **Low memory at a detach** (settled free under 256 K). The load that the user leaves is suspended at once. It does not detach. When it has no writer, it stops.
4. **Low memory during a foreground render while jobs run.** A guard settle result under reserve + 64 K suspends the oldest background job. The program suspends one job per settle. After that, the normal guard stop rules apply. This needs a new guard hook, `guard.on_low(fn)`.
5. **`too many open connections` on a foreground request.** The program suspends the oldest background job and tries the request once more.
6. **`writer.write` returns false in a job** (the page passes the cap, a disk error, or the cache is off). The job ends and its part file is deleted. The tab's job state becomes `uncached`, and the next show fetches in the foreground.
7. **A read error or a read timeout in a job.** The job is suspended.

The program always stops the oldest job first. Suspension keeps its bytes, so the loss is small. Note: one job uses about 16 K, so a suspension seldom saves a foreground render. Rules 4 and 5 protect the connections and the margin. They do not create much free memory.

## B.4 Suspend and resume

**Suspend:**
- The handle closes. `writer.suspend()` keeps the part file.
- The tab record gets `job = { state = "stopped", key, offset, length, validator }`.
  - `offset` is the number of raw bytes received (`resp.bytes`, counted before the charset step). The Latin-1 step works byte by byte, so an append at the raw offset is safe.
  - `validator` is the value of `ETag`, else of `Last-Modified`, else nil.

**Resume.** When the tab shows again, a foreground load resumes it:
1. It renders the part file first. This is a local read, and no writer has the file open.
2. When `validator` is nil, it restarts from byte 0 (user decision). The part file is truncated, and the render starts again.
3. Otherwise it requests the URL with `Range: bytes=<offset>-` and `If-Range: <validator>`. It opens the writer in append mode (`cache.resume`).
4. A `206` reply with a `Content-Range` that starts at `offset` is appended.
5. Every other reply restarts from byte 0: a `200`, a wrong range, or any case that a failed probe excludes. The part file is truncated, and the render starts again.

- Status text during a resume: `Resuming <name> at <n> KB...`.
- Until the probes P1 to P3 pass, every resume is a restart from byte 0.

## B.5 Scheduling and the return to a loading tab

- Up to 2 background jobs run at a time. Each job is a coroutine. The `fetch` sleep in a job yields `("wait", 0.05)`.
- A new pure module, `lib/html/jobs.lua`, keeps the job list: round robin, the limit of 2, and the oldest-first suspension.
- The viewer gets `opts.background = { step(), status() }`.
  - The viewer calls `step()` once per loop pass. The nested prompts and popups call it too, as they do for the loader.
  - `step()` resumes one job, in turn, for one card `read()`. One read costs one tick (50 ms, measured).
  - While the foreground load yields `slice`, a background step runs at most once per 0.1 s, so the render and the keys stay fast.
  - While the foreground waits or is idle, a step runs on each pass. The pull timeout is at most 0.05 s while a job is active.
  - Throughput: one read gives up to 4 KB, which is much more than the network rate of 9 to 10 KB/s (measured).
- The 30 s read timeout counts only the time while a job is driven. Each resume of a job resets its `last` time, so a job that waited or paused does not time out by mistake.
- **Return to a tab whose job still runs.** If probe P5 passes, the tab is promoted:
  1. The job pauses, and the writer flushes.
  2. The foreground render reads the part file to its end.
  3. The foreground takes over the live `resp` and the writer, on the normal path. No new connection opens.
- If P5 fails, the tab shows an empty page with `[i/n] <name> - Loading in background <n> KB of <m> KB`. When the job ends, the tab renders from the cache.
- `z` on that tab stops the job, deletes the part file and shows `[aborted] <target>`.
- `r` on that tab stops the job and reloads in the foreground.

## B.6 Status line

- The tab prefix becomes `[<i>/<n>{ +<k>}{ !}]`.
  - `+k`: k background loads run.
  - `!`: at least one background tab is stopped.
  - Examples: `[2/4 +1]`, `[2/4 +1 !]`. ASCII only.
- The prefix shows when 2 or more tabs are open.
- A background load that ends shows no notice. A notice would hide the title while the user reads.
- What the shown tab displays:
  - a running job: the text of B.5
  - a stopped job: a resume starts at once, with the `Resuming` phase text
  - `uncached` or `lost`: a normal foreground load

## B.7 Shell tab-out

- While the nested shell runs, the html loop does not run. Background jobs pause (user decision). Their handles stay open, and nothing reads from them.
- `!` with a foreground load: the load detaches as for a tab switch (B.1 to B.3), and then it pauses with the other jobs.
- After `exit`, the jobs go on. The read timers are reset at the return.
- A handle that the server closed gives a read error. Rule 7 of B.3 suspends that job, and a later show resumes or restarts it. Probe P4 measures how long an idle handle stays usable.
- Step 1 of the shell sequence (`spec/shell.md` "Sequence") becomes: "Detach or stop the foreground load (B.1 to B.3), write `top` and `sel`, drop `held`."
- Risk: up to 2 card connections stay open during the shell, so a program in the shell has 2 of the 4 connections.

## B.8 Cache changes (`spec/cache.md`)

- **In-flight bytes.** The budget counts total + the bytes of all writers in flight. Today each writer checks only `total + written`, so two writers can pass the cap together.
- **Suspend and resume.** `writer.suspend()` keeps the part file and returns `{ part, written }`. `cache.resume(info)` opens the part file in append mode (`"ab"`, probe P5).
- **Suspended parts are entries.** A suspended part counts as an entry for the limit of 16 and for the byte cap. It takes part in the LRU order, with its suspension time as `last_used`. When eviction removes it, the tab's job state becomes `lost`, and the next show restarts the load.
- **Writers in flight.** They are not entries until they commit. At most 3 exist at a time.
- **Files in use.** Eviction skips an entry whose file is open for reading (an `in_use` flag). In 0.7.0a only one load runs at a time. In 0.7.1a a background writer can evict while a replay reads.
- **Caps.** They do not change: 16 entries, min(25% of free disk, 2 MiB, free − 64 K). The cache does not pin pages. The finished page of a background tab can be evicted before the return, and then it is fetched again.
- **Exit.** `cache.clear()` on exit also deletes the suspended parts. 0.8.0a (session retention) decides whether parts survive a restart.

## B.9 Tab record in 0.7.1a

The `job` field that 0.7.0a reserved becomes:

```
job = nil | { state = "loading" | "stopped" | "lost" | "uncached",
              key = <cache key>, offset = <raw bytes>, length = <int or nil>,
              validator = <string or nil> }
```

- All values are plain data.
- A snapshot (0.8.0a) saves `loading` as `stopped`.
- Showing a tab (`spec/tabs.md` "Showing a tab") gets the job cases before the `switch` load:
  - `loading`: promote, or wait (B.5)
  - `stopped`: resume (B.4)
  - `lost` or `uncached`: a fetch

## B.10 Probes (in game, before the resume and promote slices)

| Probe | Question | Tool | Effect when it fails |
|---|---|---|---|
| P1 | Does the card send our request headers (`Range`, `If-Range`)? Does `response()` give 206 and `Content-Range`? (The User-Agent we send is not confirmed either; FACTS.md lists the card's default headers.) | extend `tools/netprobe.lua` | Every resume restarts. |
| P2 | Does a redirect that the card follows keep the `Range` header? | `tools/netprobe.lua` | A resume after a redirect restarts. |
| P3 | Do the response headers include `ETag` and `Last-Modified`? | `tools/netprobe.lua` | No validator, so a restart. |
| P4 | Can an idle open card handle still be read after 60 s and after 300 s? | `tools/netprobe.lua` | Sets the expectations for the shell pause (B.7). |
| P5 | Can a second handle read a file while another handle writes it (after `flush`)? Does `io.open(path, "ab")` append? | new `tools/fileprobe.lua` | No read: no promote, wait and then render (B.5). No append: every resume restarts. |
| P6 | What does one background job use in memory, and does it stay flat? | `tools/fileprobe.lua` | Change the 16 K estimate and the 256 K threshold. |

The results go into `datacollection/` and `docs/probe/FACTS.md`.

## B.11 Implementation slices for 0.7.1a

| Slice | Content | Files | Tests |
|---|---|---|---|
| P | Probes P1 to P6 in game. They gate B5 and B6. | `tools/netprobe.lua`, `tools/fileprobe.lua`, `docs/ingame/fileprobe.md`, `docs/netprobe-plan.md` | `tests/netprobe_test.lua` for the new groups |
| B1 | Cache: in-flight bytes, `suspend` and `resume`, `in_use`, suspended parts as entries. | `lib/html/cache.lua`, `tests/cache_test.lua` | — |
| B2 | Loader detach exit. `lib/html/jobs.lua` (limit 2, round robin, oldest-first suspension). The detach checks of B.2. The `opts.background` hook in the viewer loop, prompts and popups. The prefix markers. | `bin/html.lua`, `lib/html/jobs.lua`, `lib/html/viewer.lua`, `tests/jobs_test.lua`, `tests/entry_test.lua`, `tests/viewer_test.lua` | A switch during a load, then the load ends in the background, then a return renders with no new request (count the requests on the fake card). A third detach suspends the oldest job. The markers show. |
| B3 | Fallbacks of B.3: `guard.on_low`, the retry after `too many open connections`, writer false. | `lib/html/guard.lua`, `bin/html.lua`, `tests/guard_test.lua`, `tests/entry_test.lua` | Low memory in the shim suspends the oldest job. |
| B4 | The job state in the tab record; showing a tab with a job (B.9). | `lib/html/tabs.lua`, `bin/html.lua`, `tests/tabs_test.lua` | — |
| B5 | Resume: the fetch option `range = { offset, validator }` (sends `Range` and `If-Range`, accepts 206, reports the `Content-Range` start, the validator headers and the raw byte count). The 206 and 200 handling. A restart when there is no validator. | `lib/html/fetch.lua`, `tests/fetch_test.lua`, `tests/shim/internet.lua` (Range support behind an option) | — |
| B6 | Promote on return (only if P5 passes), else wait and then render. | `bin/html.lua` | — |
| B7 | Shell pause: jobs pause during the shell, and the timers reset at the return. | `bin/html.lua`, `tests/entry_test.lua` | Jobs do not advance during the fake shell, and they go on after it. |
| B8 | Release 0.7.1a: `fetch.VERSION`, `docs/ingame/0.7.1a.md`, `pwsh tools/release.ps1 0.7.1a`. | — | — |

Spec changes for 0.7.1a:
- `spec/background.md`: the status changes from "planned" to "approved".
- `spec/tabs.md`: B.6 and B.9.
- `spec/cache.md`: B.8.
- `spec/fetch.md`: the `range` option.
- `spec/guard.md`: `guard.on_low(fn)`.
- `spec/loading.md` and `spec/navigation.md`: the detach exit and the `Resuming` phase text.
- `spec/viewer.md`: `opts.background` and the markers.
- `spec/shell.md`: B.7.

## B.12 In-game checklist outline: `docs/ingame/0.7.1a.md`

0. Probes P1 to P6. Paste the reports into `datacollection/`.
1. Background loads
   - 1.1 Switch during a slow load. The prefix shows `+1`. Wait, then switch back. The page shows with no `Connecting` text.
   - 1.2 Switch back while the load still runs. Write down which behavior shows: promote (the page shows and grows), or the background status text.
   - 1.3 Start 3 slow loads in 3 tabs. The oldest stops, and `!` shows. Show that tab. Write down which behavior shows: a resume (`Resuming ... at <n> KB`) or a restart.
   - 1.4 Measure the key reaction time during 2 background loads plus a foreground render (expected under about 0.3 s).
   - 1.5 Free memory before and after 2 background loads start (expected change under about 40 K).
   - 1.6 A background page over the cache cap. The tab comes back as `uncached` and fetches.
   - 1.7 Switch during phase 1. A return loads the link again (the 0.7.0a rule stays).
2. Shell
   - 2.1 `!` during a load. After `exit`, the prefix shows `+1`, and the load finishes.
   - 2.2 Stay 5 minutes in the shell during a load. After `exit`, write down which behavior shows: the load resumes, restarts or finishes.
3. Regression: the 0.7.0a checklist sections 2 to 5.

## B.13 Open questions for 0.7.1a

None. The user decided on 2026-11-17 that background loads pause during the shell, and that a resume without a validator restarts from byte 0. The probe results can change B.4 and B.5. The spec records each such change after the probes run.