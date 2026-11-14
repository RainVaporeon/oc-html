# Machine facts (ground truth)

Measured in game with `tools/probe.lua` (probe v1). One computer, OpenOS 1.8.9, Lua 5.3, two Tier 3 memory sticks.
Later tasks use these numbers. When a new measurement differs, update this file.

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
| Yields do not force a GC | readings still jump after yields | `memory.method=yield_max_of_5` |
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
| plain `string.find` | 6338 KB/s | `timing.find_lt.kb_per_s` |
| `string.byte` loop | 33761 KB/s | `timing.byte_loop.kb_per_s` |
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

## GPU

| Fact | Source key |
|---|---|
| Depth 8 (t3), 4 (t2), 1 (t1). Depth 1 has no palette | `gpu.depth`, `gpu.palette` |
| The current resolution can differ from the max (t3: 120x60, max 160x50). Set by the user before the run. The default is 160x50. | `gpu.resolution`, `gpu.max_resolution` |
| One `set` costs the same for 1 or 160 chars: about 7600/s at tier 3, 3800/s at tier 2 | `gpu.set1.per_s`, `gpu.set160.per_s` |
| `setForeground` costs as much as a `fill`, also with the same color | `gpu.fg_same.per_s`, `gpu.fill160.per_s` |
| `copy` 160x10: about 1800/s at tier 3, 960/s at tier 2 | `gpu.copy160x10.per_s` |
| A full 50-line redraw fits in one tick (wall 0 ms) | `gpu.redraw50.*` |
| After a wide char at x, `get(x+1)` returns a space | `gpu.wide.get2` |
| GPU buffers exist on all tiers | `gpu.has.allocateBuffer`, `gpu.buffer.index` |

## Keys (t3)

| Key | Code | Key | Code |
|---|---|---|---|
| up | 200 | end | 207 |
| down | 208 | q | 16 |
| pageUp | 201 | enter | 28 |
| pageDown | 209 | c | 46 |
| home | 199 | lcontrol | 29 |

Source keys: `keyboard.keys.*`.

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
- The user could not redirect stderr to a file in game. From 0.0.2a, `--stats-out <path>` writes the stats lines to a file.

## Components (t3)

- Internet card: HTTP and TCP enabled (`extras.internet.*`).
- No data card (`extras.data.present=false`).
