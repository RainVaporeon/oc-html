# In-game check: probe v2

Goal: measure the open assumptions of Tasks 4, 7, 8, 10 and 11 in one run,
and run the installed 0.0.4a renderer on `wiki.html` and `large.html` with
its stats. Everything goes into one file, `probe2.txt`.

`<BASE>` is the raw URL of the repository source. Use the version path
`releases/0.0.4a/`, not `releases/latest`.

## 1. Install 0.0.4a

```
wget -f <BASE>/releases/0.0.4a/html-install.lua /home/html-install.lua
/home/html-install.lua
```

- The installer prints `html-install: oc-html 0.0.4a`, one line per file and
  `installed 6 files`.
- The probe runs `/home/bin/html.lua`. It must be 0.0.4a.

## 2. Fetch the probe and the pages

Put the probe and the two pages in the same folder, for example `/home/p2`:

```
mkdir /home/p2
wget -f <BASE>/tools/probe2.lua /home/p2/probe2.lua
wget -f <BASE>/tests/pages/large.html /home/p2/large.html
wget -f "https://en.wikipedia.org/wiki/Lua_(programming_language)" /home/p2/wiki.html
```

If `wiki.html` and `large.html` are already in `/home`, you can copy them
instead: `cp /home/wiki.html /home/large.html /home/p2/`.

## 3. Run the probe

```
/home/p2/probe2.lua
```

- The probe prints one line per section: `probe2: [1/9] env` to
  `probe2: [9/9] input`.
- The screen flickers and changes size during the `gpu` and `text`
  sections. This is expected. The probe restores the screen at the end.
- The `input` section asks for keys, one at a time. Press each key when the
  prompt asks for it: Up, Down, PgUp, PgDn, Home, End, q, Enter. Then hold
  Down for about 2 seconds and release it. Then press Ctrl+C once.
- Press plain Ctrl+C only. Do not press Ctrl+Alt+C. It kills the probe.
- Each key step waits 15 s. A missed step is recorded as `timeout`, and the
  probe goes on.
- At the end, the probe prints the output path, its size and the error
  count.

Options:

```
/home/p2/probe2.lua --no-interactive     skip the key section
/home/p2/probe2.lua --skip-render        skip the html render section
/home/p2/probe2.lua --dir <path>         folder with the pages (default: the probe folder)
/home/p2/probe2.lua --out <path>         output file (default: <dir>/probe2.txt)
```

Plain Ctrl+C outside the key section stops the probe. It still writes the
report (with `probe.interrupted=true`) and restores the screen.

### Duration

- About 1 to 2 minutes without the key section.
- The render section takes about 1 s for `wiki.html` and about 10 to 30 s
  for `large.html`.
- The key section takes as long as you need, at most 15 s per step.

## 4. Return the output

Copy `/home/p2/probe2.txt` to `./datacollection/` in the repository. If the
probe stops with an error, also paste the error text exactly as shown.

## What the probe writes

The file starts with `#probe2 v1`. Each line is `section.key=value`. A
failed test writes `ERR <message>`. The last lines are `probe.errors` and
`probe.duration_ms`.

| Section | Measures |
|---|---|
| `env` | versions, memory, GPU and screen, the probe folder and the pages |
| `render` | `html --stats` on each page: method, exit code, wall time, and every `stats:` line as `render.<page>.<key>` |
| `mem` | GC every 10th yield, cost of a table doubling, cost of 160-byte strings with style bytes |
| `fs` | rename over an existing file, `/tmp` full behavior, `shell.resolve`, drive space |
| `shell` | `>`, `>>`, `2>`, `2>&1` and the pipe, where stderr goes, `term` state |
| `gpu` | `setResolution`, `gpu.copy` speed and result, color call returns, `term` cursor after GPU drawing |
| `text` | `unicode.len`, `unicode.wlen` and the screen columns of test strings |
| `speed` | `string.find`, `string.byte`, `string.sub`, `table.concat`, `table.insert` |
| `input` | the key events, key repeat, and how Ctrl+C arrives |

The probe writes only to `/tmp` and to its output file. It removes its
temporary files. It makes no network request.
