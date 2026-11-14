# In-game check: Task 3b (release 0.0.2a, peak memory and a 1 MB page)

Goal: install 0.0.2a with the one-file installer, then measure the peak
memory use on the Wikipedia page from Task 3 and on a generated page of about
1 MB.

`<BASE>` is the raw URL of the repository source. Use the version path
`releases/0.0.2a/`, not `releases/latest`.

## 1. Install

```
wget -f <BASE>/releases/0.0.2a/html-install.lua /home/html-install.lua
/home/html-install.lua
```

- The installer prints `html-install: oc-html 0.0.2a`, one line per file with
  its size, and `installed 6 files`.
- It replaces the 0.0.1a files in `/home/bin` and `/home/lib/html`.
- To see the checks without writing, run `/home/html-install.lua --dry-run`.
- If it stops, it prints one line that starts with `html-install: `. The old
  files stay in place.

Check: `html --help` shows the `--stats-out` option.

## 2. Fetch the pages

The large page is about 1 MB. Check the free space first with `df /home`.

```
wget -f <BASE>/tests/pages/large.html /home/large.html
wget -f "https://en.wikipedia.org/wiki/Lua_(programming_language)" /home/wiki.html
ls -l /home/large.html /home/wiki.html
```

## 3. Run

```
html --stats --stats-out /home/stats-wiki.txt /home/wiki.html > /dev/null
html --stats --stats-out /home/stats-large.txt /home/large.html > /dev/null
```

- The `stats:` lines go to the screen (stderr) and to the file.
- `large.html` may stop with
  `html: page too large for available memory (rendered N lines before stopping)`.
  That is a valid result. The stats file then ends with a `stats: stopped=`
  line.
- The run must not stop with "too long without yielding".

## 4. What to paste back

1. `cat /home/stats-wiki.txt`
2. `cat /home/stats-large.txt`
3. The output of `ls -l /home/large.html /home/wiki.html`.
4. The installer output of step 1.
5. Any error text, exactly as shown. If the error mentions
   `/tmp/html-error.log`, also paste `cat /tmp/html-error.log`.

## 5. How to read the results

- `peak_used` is free_before - lowest_free. It is an upper bound of the peak
  memory use, because `lowest_free` includes garbage that is not collected
  yet.
- `delta` (free_before - free_after) is not reliable. In Task 3 it was
  negative (see `docs/probe/FACTS.md`, "Tracer bullet 0.0.1a").
- In the container, `large.html` gives 11302 lines at width 160. When the
  stats show `width=160` and the page does not stop, the in-game line count
  must be the same.
- CPU speed: Task 3 measured about 630 KB/s. At that speed `large.html`
  needs about 1.6 s of `cpu`.
