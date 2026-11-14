# Machine facts (ground truth)

Measured in game with `tools/probe.lua` (probe v1) and probe v2 (raw file `datacollection/probe2.txt`, git-ignored). One computer, OpenOS 1.8.9, Lua 5.3, two Tier 3 memory sticks.
Later tasks use these numbers. When a new measurement differs, update this file. `probe2: key=value` cites a probe v2 line.

## Runs

| File | GPU bound | Screen setup | Depth | Resolution | Mode |
|---|---|---|---|---|---|
| `probe-t1.txt` | APU (FlexiArch 3) | tier 1 screen | 1 | 50x16 | quick |
| `probe-t2.txt` | MPG2000 | tier 2 | 4 | 80x25 | quick |
| `probe-t3.txt` | MPG3000 | tier 3 | 8 | 120x60 (max 160x50) | full |
| `probe-t3b.txt` | APU (FlexiArch 3) | tier 3, after reboot | 8 | 160x50 | quick |

Only t3 is a full run. The `memory.*`, `timing.*`, `file.*`, `keyboard.*` and `extras.*` facts come from t3 only.

## Known probe bugs (not machine faults)

Every run reports `probe.errors=2`. Both errors are probe bugs. The probe stays as it is.

1. `lua.collectgarbage_count=ERR ... (global 'collectgarbage')`: the probe calls `collectgarbage` without a check. OpenComputers removes it on purpose.
2. `text.char.110000=ERR Not a valid Unicode code point`: the probe calls `unicode.char(0x110000)` to test the throw, and counts it as an error.

## Error behavior (t3 vs t3b)

| Key | t1, t2, t3b | t3 |
|---|---|---|
| `lua.error_table_pcall` | `table:x` | `string:false` |
| `lua.error_table_xpcall_traceback` | `table:x` | `string:false` |
| `lua.traceback_in_xpcall` | `true` | `false` |
| `lua.error_level0` | `msg` | `table: 0x...` |
| `lua.error_level1` | `<file>:585: msg` | `table: 0x...` |

- t3b (after a reboot) is normal. The t3 result is a fault of that session, not of the machine.
- In t3, string errors also came back as tables. No error design survives that state.
- t3 had run for about 87 minutes (`env.uptime_ms=5194950`). Its palette was also changed (`gpu.palette.0=0xF97C70`). Another program probably changed the global state before the probe ran.
- Design result: controlled errors are strings with the prefix `html: `. An error that is not a string, or has no prefix, is handled as unexpected.

## Lua environment

| Fact | Source key |
|---|---|
| `collectgarbage` is nil | `lua.has.collectgarbage` |
| `debug` has only getinfo, getlocal, getupvalue, traceback | `lua.debug_functions.1` |
| `debug.sethook`, `loadstring`, `setfenv`, `bit32` are nil | `lua.has.*` |
| `load` with an env works. Binary chunks are refused | `lua.load_env_isolated`, `lua.load_binary_refused` |
| Yield and `os.sleep` work inside `pcall` | `lua.yield_in_pcall`, `lua.sleep_in_pcall` |
| Integers are 8 bytes | `lua.integer_bytes` |

## Memory (t3)

| Fact | Value | Source key |
|---|---|---|
| Total memory | 2097152 (2 MiB) | `memory.total` |
| Free memory | about 1.8 MB | `memory.free` |
| freeMemory jitter | up to 213499 bytes. The first reading is lowest | `memory.noise.readings`, `memory.noise.spread` |
| Every 10th yield forces a full GC (kernel); other yields do not | the probe used 5 yields, which can miss the 10th. memprobe 0.0.3a: free memory jumps at yields 7 and 17 of 20. Probe v2: also under load (16 KB of garbage per yield), jumps at yields 8, 18, 28, 38 | `memory.method=yield_max_of_5`, `h2.after_yields`, `probe2: mem.gc10.intervals=10,10,10` |
| ramScale | 1.800 exactly: a table doubling from 8192 to 16384 slots (131072 real bytes) cost 72818 scaled units, twice | `probe2: mem.doubling.1.cost=72818`, `mem.doubling.2.cost=72818` |
| Table doubling | from capacity c to 2c needs about 32 * c / 1.8 scaled units at once (8192 slots: 145636) | `probe2: mem.doubling.*` |
| Style byte | 1 real byte each: a 160-char string costs 102.8 scaled units, with 3 style bytes 104.4, with 10 style bytes 108.3. The line format stays | `probe2: mem.str160.*` |
| Empty table | 25 bytes | `memory.empty_table.bytes_per_item` |
| 4-field table | 61 bytes | `memory.table4.bytes_per_item` |

Line formats, average line 82 chars:

| Format | Bytes per line at 10000 lines | Result | Source key |
|---|---|---|---|
| plain string | 78 | 10000 lines | `memory.lines.plain.10000` |
| inline style bytes | 80 | 10000 lines | `memory.lines.inline.10000` |
| flat table | 170 | stopped at 5461 | `memory.lines.flat.10000` |
| list of runs | 322 | stopped at 5185 | `memory.lines.runs.10000` |

Decision: a line is one string with inline style bytes.

## Timing (t3)

| Fact | Value | Source key |
|---|---|---|
| `os.clock` | sub-millisecond steps, counts Lua CPU time | `timing.os_clock.*` |
| `computer.uptime` | 50 ms steps | `timing.uptime.busy_min_step_ms` |
| `os.sleep(0)` | 10 ms wall, 0.27 ms CPU | `timing.sleep0.*` |
| `event.pull(0)` | 15 ms wall, 0.33 ms CPU | `timing.pull_signal0.*` |
| plain `string.find` | 6338 KB/s. Probe v2: 6821 KB/s, about 3.2 us per call | `timing.find_lt.kb_per_s`, `probe2: speed.find_lt.kb_per_s=6821.5` |
| `string.byte` loop | 33761 KB/s | `timing.byte_loop.kb_per_s` |
| `string.byte(s, i)`, 1 byte per call | about 61 ns per call (16057 KB/s) | `probe2: speed.byte_1.kb_per_s=16057.3` |
| `string.sub` of 80 bytes | about 260 ns per call | `probe2: speed.sub_80.*` |
| `t[#t+1] = v` against `table.insert` | 17.2 M against 9.0 M ops/s | `probe2: speed.index_append_1000.ops_per_s`, `speed.table_insert_1000.ops_per_s` |
| `gmatch` words | 248 KB/s | `timing.gmatch_words.kb_per_s` |
| `gsub` | 94 KB/s. One gsub over 64 KB ran 679 ms with no yield | `timing.gsub_space.*` |
| `unicode.wlen` | fast (170 MB/s on mixed text) | `timing.unicode_wlen.kb_per_s` |

## Files (t3)

| Fact | Source key |
|---|---|
| `io` `f:read(n)` returns n bytes | `file.*.io.*.first` |
| The raw filesystem proxy returns at most 2048 bytes per call | `file.*.raw.4096.first` |
| Throughput about 320 to 430 KB/s | `file.*.io.*.kb_per_s` |
| No newline translation. `\r` stays in the data | `file.textmode.*` |
| `/tmp` is 64 KB (65536) | `file.tmp.total` |
| Rename over an existing file replaces it. Measured on tmpfs with `filesystem.rename` and `os.rename`. The user also checked on the HDD: `touch p; touch u; mv p u` replaces u with p | `probe2: fs.rename_fs.result=replaced`, `fs.rename_os.result=replaced` |
| `/tmp` full: `write` returns success (buffered). The error "not enough space" comes at flush (or close) | `probe2: fs.fill.error=flush: not enough space` |
| `shell.resolve` does not expand `~` | `probe2: fs.resolve.home=/home/~` |

## Shell (probe v2)

| Fact | Source key |
|---|---|
| `>`, `>>`, `2>`, `2>&1` and `\|` all work | `probe2: shell.gt.*`, `shell.gtgt.*`, `shell.err2.*`, `shell.err2to1.*`, `shell.pipe.*` |
| When stdout is redirected, stderr still goes to the screen | `probe2: shell.stderr.file=P2OUT\x0A`, `shell.stderr.on_screen_row=1` |

## Text (all runs, same result)

| Input | Bytes | `unicode.len` | `unicode.wlen` | `utf8.len` | `unicode.sub(s,1,2)` | Source key |
|---|---|---|---|---|---|---|
| CJK 中文 | E4B8AD E69687 | 2 | 4 | 2 | same | `text.zh.*` |
| emoji 😀 | F09F9880 | 1 | 2 | 1 | same | `text.emoji.*` |
| U+200B | E2808B | 1 | 2 (isWide true) | 1 | same | `text.zwsp.*` |
| combining e + U+0301 | 65 CC81 | 2 | 2 | 2 | same | `text.combining.*` |
| lone 0x80 | 80 | 1 | 1 | nil@1 | U+FFFD | `text.lone_cont.*` |
| truncated | E4 B8 | 1 | 1 | nil@1 | U+FFFD | `text.truncated.*` |
| overlong | C0 AF | 2 | 2 | nil@1 | two U+FFFD | `text.overlong.*` |
| surrogate | ED A0 80 | 1 | 1 | 1 | U+FFFD | `text.surrogate.*` |

- `unicode.*` never throws on bad bytes. It turns them into U+FFFD.
- `utf8.len` accepts encoded surrogates. It does not prove that text is clean.
- `unicode.char` throws above 0x10FFFF (`text.char.110000`).
- `unicode.wtrunc("中文abc", 3)` gives `中` (`text.wtrunc_zh_3`).

Probe v2 drew each string with `gpu.set` and counted the screen columns. `wlen` equals the columns in every case.

| Input | Bytes | `unicode.len` | `unicode.wlen` | Columns | Source key |
|---|---|---|---|---|---|
| Hangul 한국어 | ED959C EAB5AD EC96B4 | 3 | 6 | 6 | `probe2: text.hangul.*` |
| Arabic | D8B9 D8B1 D8A8 D98A | 4 | 4 | 4 | `probe2: text.arabic.*` |
| box drawing ┌─┐ | E2948C E29480 E29490 | 3 | 3 | 3 | `probe2: text.box.*` |
| Greek αβγ | CEB1 CEB2 CEB3 | 3 | 3 | 3 | `probe2: text.greek.*` |
| combining e + U+0301 | 65 CC81 | 2 | 2 | 2 (the mark takes its own cell) | `probe2: text.combining.*` |
| ☺ + U+FE0F | E298BA EFB88F | 2 | 3 (U+FE0F is wide) | 3 | `probe2: text.vs16.*` |
| fullwidth Ａ | EFBCA1 | 1 | 2 | 2 | `probe2: text.fullwidth.*` |
| `a\tb` | 61 09 62 | 3 | 4 (tab is a 2-cell glyph) | 4 | `probe2: text.tab.*` |

- A tab is drawn as a 2-cell glyph, not as a jump to a tab stop.
- U+FE0F (variation selector 16) is wide. The text cleaning removes U+FE00 to U+FE0F.

## GPU

| Fact | Source key |
|---|---|
| Depth 8 (t3), 4 (t2), 1 (t1). Depth 1 has no palette | `gpu.depth`, `gpu.palette` |
| The current resolution can differ from the max (t3: 120x60, max 160x50). Set by the user before the run. The default is 160x50. | `gpu.resolution`, `gpu.max_resolution` |
| One `set` costs the same for 1 or 160 chars: about 7600/s at tier 3, 3800/s at tier 2 | `gpu.set1.per_s`, `gpu.set160.per_s` |
| `setForeground` costs as much as a `fill`, also with the same color. `setForeground` and `setBackground` return the old color. Same-color calls: about 3830/s | `gpu.fg_same.per_s`, `gpu.fill160.per_s`, `probe2: gpu.fg.returns_old=true`, `gpu.fg.same.per_s=3832.5` |
| `setResolution` works. Each call costs one tick (50 ms wall) | `probe2: gpu.res.set_wall_ms=50.000`, `gpu.res.restored_ok=true` |
| `copy` is correct and leaves the source row as it was, so the new row must be drawn. 160x48: about 2000/s | `probe2: gpu.copy.correct=true`, `gpu.copy.last_row_kept=true`, `gpu.copy.repeat.per_s=2000.0` |
| The `term` cursor is stale after direct GPU drawing | `probe2: gpu.term.*` |
| `copy` 160x10: about 1800/s at tier 3, 960/s at tier 2 | `gpu.copy160x10.per_s` |
| A full 50-line redraw fits in one tick (wall 0 ms) | `gpu.redraw50.*` |
| After a wide char at x, `get(x+1)` returns a space | `gpu.wide.get2` |
| GPU buffers exist on all tiers | `gpu.has.allocateBuffer`, `gpu.buffer.index` |

## Keys

Standard codes (t3, from the `keyboard` library):

| Key | Code | Key | Code |
|---|---|---|---|
| up | 200 | end | 207 |
| down | 208 | q | 16 |
| pageUp | 201 | enter | 28 |
| pageDown | 209 | c | 46 |
| home | 199 | lcontrol | 29 |

Source keys: `keyboard.keys.*`.

Measured key presses (probe v2):

| Key pressed | `key_down` char | code | Source key |
|---|---|---|---|
| Up | 0 | 200 | `probe2: input.up.*` |
| Down | 0 | 208 | `probe2: input.down.*` |
| PgUp | 0 | 73 | `probe2: input.pgup.*` |
| PgDn | 0 | 81 | `probe2: input.pgdn.*` |
| Home | 0 | 71 | `probe2: input.home.*` |
| End | 0 | 79 | `probe2: input.end.*` |
| q | 113 | 16 | `probe2: input.q.*` |
| Enter | 13 | 28 | `probe2: input.enter.*` |

- The user's keyboard sends PgUp, PgDn, Home and End through the NumPad with NumLock off: codes 73, 81, 71 and 79 with char 0. An online keyboard test shows these keys as real PgUp, PgDn, Home and End.
- With NumLock on, NumPad 9 sends code 73 with char '9' (57). The NumLock-on char value is expected, not measured.
- Rule (user): a NumPad digit must not act as a navigation key. The NumPad codes 71, 72, 73, 79, 80 and 81 are Home, Up, PgUp, End, Down and PgDn only when char is 0. The standard codes 199, 200, 201, 207, 208 and 209 are always accepted.
- Ctrl+C arrives as `key_down` code 29 (ctrl), then `key_down` char 3 code 46, then an "interrupted" event from `event.pull`. It is an event, not an error. Source: `probe2: input.ctrl_c.events`.
- Key repeat: 500 ms delay, then about 28 events per second (24 events in 1.3 s). Source: `probe2: input.hold.*`.

## Tracer bullet 0.0.1a

Measured in game with release 0.0.1a (`html --stats`), tier 3, 2 MiB. Steps: `docs/ingame/task3.md`.

| Fact | Value |
|---|---|
| `basic.html` at `--width 40` | same text as `basic.txt` |
| Page | Wikipedia article, 98891 bytes |
| Width | 160 |
| Lines | 182 |
| `cpu` (tokenizer and layout) | 0.156 s |
| `wall` | 0.25 s |
| `free_before` | 1684554 |
| `free_after` | 1848752 |
| `used` (free_before - free_after) | -164198 |

- CPU speed: about 630 KB/s (98891 bytes in 0.156 s) for the minimal tokenizer and layout. A 1 MB page needs about 1.6 s of CPU at this speed. The full tokenizer and layout will be slower.
- No yield error on the 100 KB page.
- The memory delta cannot be measured this way. The game has no `collectgarbage`, so `freeMemory()` includes garbage. Garbage from module loading was collected during the run, so free memory was higher after the render. From 0.0.2a, `--stats` also reports `lowest_free` and `peak_used` (free_before - lowest_free), and the delta is named `delta`.
- From 0.0.2a, `--stats-out <path>` writes the stats lines to a file. (An earlier note here said that stderr could not be redirected in game. That was wrong: probe v2 measured that `2>` and `2>&1` work. See "Shell".)

## Release 0.0.2a on large.html

Reported by the user in game. Installed with `html-install.lua` over 0.0.1a, without a reboot. Steps: `docs/ingame/task3b.md`.

| Fact | Value |
|---|---|
| Command | `html --stats --stats-out ... /home/large.html` |
| Result | stopped with "html: page too large for available memory" after 1984 lines |
| Then | crash at `html.lua:168` in `report_stats`: "attempt to call a nil value (field 'lowest_free')" |
| Container result for the same page | 11302 lines at width 160 |

- 1984 lines of at most 160 characters are far less than the about 1.68 MB free at start. The guard probably stopped on garbage, not on live data (see H2).
- The crash: the cached 0.0.1a `html.guard` had no `lowest_free` (see H1). Fixed in 0.0.3a.

## Module cache and memory limit (from source, measured with 0.0.3a)

These facts come from the source code. `tools/memprobe.lua` (Task 3c, `docs/ingame/task3c.md`) measured H1 and H2 in game with 0.0.3a. The raw file is `datacollection/memprobe.txt` (git-ignored).

### H1: OpenOS keeps modules between program runs (measured)

- Measured: `h1.result=kept`. The second run found the marker of the first run in the same `package.loaded` table (`h1.step2.same_loaded_table=true`, `h1.step2.marker_present=true`). The table stays until a reboot. 0.0.3a clears the `html.*` modules correctly.

- `package.loaded` is one plain table, created once at boot. It has no weak mode. `require` returns `loaded[name]` when it is not nil and stores every new module there. No code in the file removes an entry. Source: [package.lua L11-L21](https://github.com/MightyPirates/OpenComputers/blob/667626d8e2fbd3b68ed6b80e9ed9921a6de265b6/src/main/resources/assets/opencomputers/loot/openos/lib/package.lua#L11-L21), [L76-L99](https://github.com/MightyPirates/OpenComputers/blob/667626d8e2fbd3b68ed6b80e9ed9921a6de265b6/src/main/resources/assets/opencomputers/loot/openos/lib/package.lua#L76-L99).
- A program is loaded with `loadfile(program, "bt", env)` each run, so `bin/html.lua` is always fresh. The process library has no per-process `package` and does not clean `package.loaded` when a process ends. Source: [process.lua L52](https://github.com/MightyPirates/OpenComputers/blob/667626d8e2fbd3b68ed6b80e9ed9921a6de265b6/src/main/resources/assets/opencomputers/loot/openos/lib/process.lua#L52).
- Result: until a reboot, `require("html.guard")` returns the module of the first run. This explains the 0.0.2a crash. It also keeps the module memory after a run.

### H2: the memory limit and garbage (measured)

- Measured: `h2.try2` allocated a 951 KB string (`h2.try2.size=950998`). Free memory rose by 725606 while the program held it (`h2.try2.free_before=688854`, `h2.try2.free_holding=1414460`): the allocation ran a GC that collected the garbage. Garbage never makes an allocation fail.
- Measured: `h2.after_yields` (20 readings, one `os.sleep(0)` each) jumps at yields 7 (+538330) and 17 (+13290). So the kernel runs a full GC on every 10th resume. The phase is arbitrary, so a GC comes within at most 10 yields.
- Memprobe limitation: it compared string sizes in real bytes with `freeMemory()`, which is in scaled units (real / ramScale). The sizes and the free values in its output are not in the same unit.

- OpenComputers 1.7.10 with Lua 5.3 uses the natives of [OC-Natives branch master-Lua5.3](https://github.com/MightyPirates/OC-Natives/tree/master-Lua5.3): JNLua `89081ae` and Eris (Lua 5.3.2) `683ac97`.
- The limit is in the allocator. `l_alloc_checked` counts every allocated byte and returns NULL when `total - used < delta`. Freeing and shrinking always succeed. Source: [jnlua.c L210-L248](https://github.com/fnuecke/jnlua/blob/89081aee7d9df1e5e29c0181a3907e6146538b69/jnlua/src/main/c/jnlua.c#L210-L248).
- Free memory is `max(0, total - used)`. `used` includes garbage that is not collected yet. Source: [LuaState.java L468-L474](https://github.com/fnuecke/jnlua/blob/89081aee7d9df1e5e29c0181a3907e6146538b69/jnlua/src/main/java/li/cil/repack/com/naef/jnlua/LuaState.java#L468-L474).
- When the allocator returns NULL, Lua runs a full GC and tries once more (emergency GC). Only when the second try fails does it raise "not enough memory". Source: [lmem.c L86-L95](https://github.com/fnuecke/eris/blob/683ac97476a8634d9e5c17f0dec8dff8b7f3e595/src/lmem.c#L86-L95).
- So the real limit is reached only when an allocation fails after a full GC. A `freeMemory()` reading below the reserve can still have a lot of collectable garbage.
- `computer.freeMemory()` and `totalMemory()` are scaled: the value is the real free memory divided by `ramScale`. On a 64-bit host the default `ramScaleFor64Bit` is 1.8. Measured in game: ramScale is 1.800 (probe v2, table doubling), and `totalMemory()` reads 2097152. So 1 byte of reported free memory is about 1.8 real bytes. Source: [ComputerAPI.scala L42-L48](https://github.com/MightyPirates/OpenComputers/blob/667626d8e2fbd3b68ed6b80e9ed9921a6de265b6/src/main/scala/li/cil/oc/server/machine/luac/ComputerAPI.scala#L42-L48), [application.conf L259-L265](https://github.com/MightyPirates/OpenComputers/blob/667626d8e2fbd3b68ed6b80e9ed9921a6de265b6/src/main/resources/application.conf#L259-L265). The server config can change it.
- The kernel runs `collectgarbage("collect")` before every 10th resume of the main OpenOS coroutine (native Lua only, where `persistKey` exists). A resume follows each yield to the machine, for example `os.sleep(0)`. So every 10th yield forces a full GC (measured, see above). Source: [machine.lua L1515-L1528](https://github.com/MightyPirates/OpenComputers/blob/667626d8e2fbd3b68ed6b80e9ed9921a6de265b6/src/main/resources/assets/opencomputers/lua/machine.lua#L1515-L1528), [PersistenceAPI.scala L15-L21](https://github.com/MightyPirates/OpenComputers/blob/667626d8e2fbd3b68ed6b80e9ed9921a6de265b6/src/main/scala/li/cil/oc/server/machine/luac/PersistenceAPI.scala#L15-L21). This does not contradict "Yields do not force a GC" above: that probe used 5 yields, which can miss the 10th resume.
- In 0.0.3a, `guard.settled_free()` used 3 yields. It could miss the forced GC. Guard v2 (0.0.4a) yields up to 11 times and stops at the first GC (see `spec/guard.md` "Settle").

## Release 0.0.3a stats

Measured in game with 0.0.3a (`html --stats --stats-out`), width 160. Raw files: `datacollection/stats-wiki.txt`, `datacollection/stats-large.txt` (git-ignored).

| Fact | Wiki page | large.html |
|---|---|---|
| File | 98891 bytes | 1000193 bytes |
| Lines | 182 (all) | stopped at 1803 of 11302 |
| `cpu` / `wall` | 0.158 s / 0.30 s | n/a (stopped) |
| `free_before` | 1731712 | 1828996 |
| `lowest_free` | 764734 | 125930 |
| `peak_used` | 966978 | 1703066 |

- The trace is a saw-tooth: the incremental GC frees garbage during the render with no yield. Raw readings can be up to about 1.3 MB too low (large: `1800:225526` against about 1.5 M after GC). The wiki trace swings about 700 KB.
- None of the three settle readings of the 0.0.3a guard caught a GC. The large.html stop was a false stop on garbage.
- Fixed overhead: about 280 K scaled. (The 0.0.3a live cost estimate of 160 to 410 scaled units per line was wrong. See "Release 0.0.4a stats".)
- `os.sleep(0)` costs about 10 ms wall time.

## Release 0.0.4a stats (probe v2)

Measured in game with 0.0.4a by probe v2, width 160, tier 3 APU, 2 MiB.

| Fact | Wiki page | large.html |
|---|---|---|
| File | 98891 bytes | 1000193 bytes |
| Lines | 182 (all) | 11302 (all) |
| `cpu` / `wall` | 0.129 s / 0.25 s | 3.998 s / 4.75 s |
| `free_before` / `free_after` | 1810593 / 1802707 | 1808728 / 1056814 |
| `lowest_free` | 701592 | 0 |
| `settles` / `gc_seen` / `settle_yields` | 1 / 1 / 6 | 12 / 12 / 118 |

Source keys: `probe2: render.wiki.*`, `render.large.*`.

- large.html rendered all 11302 lines. The 0.0.3a stop at 1803 lines was a false stop on garbage.
- Live cost: about 66.5 scaled units per line (`probe2: render.large.delta=751914 bytes (66.5 per line)`), 46 to 76 between settle points that saw a GC.
- `lowest_free` 0 is real. The heap hit the limit when the lines table grew from 8192 to 16384 slots (trace sample `8187:78737`, then 0). An emergency GC saved the render. Guard change: the reserve covers the next table doubling (`spec/guard.md` "Memory reserve").

## Components (t3)

- Internet card: HTTP and TCP enabled (`extras.internet.*`).
- No data card (`extras.data.present=false`).
