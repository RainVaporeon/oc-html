# In-game check: Task 3 (tracer bullet)

Goal: run the tracer bullet on the real machine (tier 3, 2 MiB) and confirm the
numbers in `docs/probe/FACTS.md`.

## 1. Fetch the files

Fetch each file from the remote source to the path in the right column.
`<BASE>` is the raw URL of the repository source.
`releases/latest` is a symlink, and the host may not follow it. Use the version
path `releases/0.0.1a/`.
`releases/0.0.1a/release.tar.gz` holds the same files, for transfer outside the
game.

| Source file (`bin/` and `lib/` are under `releases/0.0.1a/`) | Path in game |
|---|---|
| `bin/html.lua` | `/home/bin/html.lua` |
| `lib/html/guard.lua` | `/home/lib/html/guard.lua` |
| `lib/html/text.lua` | `/home/lib/html/text.lua` |
| `lib/html/entities.lua` | `/home/lib/html/entities.lua` |
| `lib/html/tokenizer.lua` | `/home/lib/html/tokenizer.lua` |
| `lib/html/layout.lua` | `/home/lib/html/layout.lua` |
| `tests/cases/basic.html` | `/home/basic.html` |
| `tests/cases/basic.txt` | `/home/basic.txt` |

Example commands:

```
mkdir /home/bin
mkdir /home/lib/html
wget -f <BASE>/releases/0.0.1a/bin/html.lua /home/bin/html.lua
wget -f <BASE>/releases/0.0.1a/lib/html/guard.lua /home/lib/html/guard.lua
wget -f <BASE>/releases/0.0.1a/lib/html/text.lua /home/lib/html/text.lua
wget -f <BASE>/releases/0.0.1a/lib/html/entities.lua /home/lib/html/entities.lua
wget -f <BASE>/releases/0.0.1a/lib/html/tokenizer.lua /home/lib/html/tokenizer.lua
wget -f <BASE>/releases/0.0.1a/lib/html/layout.lua /home/lib/html/layout.lua
wget -f <BASE>/tests/cases/basic.html /home/basic.html
wget -f <BASE>/tests/cases/basic.txt /home/basic.txt
```

Check: `html --help` prints the usage. If it says "module not found", check
the paths above.

## 2. Small page

```
html --width 40 --stats /home/basic.html
cat /home/basic.txt
```

- The text of the first command must be the same as `basic.txt`.
- `--width 40` is needed, because `basic.txt` is wrapped at 40 columns.
  Without `--width`, the program uses the screen width.
- The `stats:` lines come at the end. They go to stderr.

## 3. Page of about 100 KB

Fetch one Wikipedia article. Its size changes over time and is usually 100 to
300 KB. Any page of 100 KB or more is good.

```
wget -f "https://en.wikipedia.org/wiki/Lua_(programming_language)" /home/wiki.html
ls -l /home/wiki.html
html --stats /home/wiki.html > /dev/null
```

- `> /dev/null` hides the page text and shows only the `stats:` lines. This
  keeps the screen output short. If the redirect does not work, run
  `html --stats /home/wiki.html` and wait for the end of the output.
- The run must finish without "too long without yielding".

## 4. What to paste back

1. The full `stats:` output of step 2 and of step 3.
2. Whether the text of step 2 is the same as `basic.txt`. If not, the
   different lines.
3. The output of `ls -l /home/wiki.html`.
4. Any error text, exactly as shown. If the error mentions
   `/tmp/html-error.log`, also paste `cat /tmp/html-error.log`.

## 5. How the results confirm FACTS.md

The `--stats` output has these lines:

```
stats: file=<bytes> bytes
stats: width=<columns>
stats: lines=<count>
stats: cpu=<seconds> s
stats: wall=<seconds> s
stats: free_before=<bytes> bytes
stats: free_after=<bytes> bytes
stats: used=<bytes> bytes (<bytes> per line)
```

- Render speed: `cpu` is the `os.clock` time of the tokenizer and layout.
  The estimate is about 1 to 2 s for 100 KB. `wall` includes the yields
  (about 10 ms each, one per second of CPU). A result within twice the
  estimate confirms FACTS.md. A slower result is a finding for Task 4.
- Memory per line: `used` divided by `lines`. FACTS.md measured 80 bytes per
  line for an 82-character line. A Wikipedia line at 160 columns is longer,
  and `used` also counts garbage that is not collected yet. So a value of
  80 to about 250 bytes per line agrees with FACTS.md. A much higher value is
  a finding.
- `free_before` should be about 1.8 MB on a machine with 2 MiB, as in
  FACTS.md (`memory.free`).
- The page finishes without a yield error. This confirms the guard values
  (`YIELD_INTERVAL` 1 s with `os.clock`).
