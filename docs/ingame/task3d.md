# In-game check: Task 3d (release 0.0.4a, guard v2)

Goal: install 0.0.4a and get the stats of the Wikipedia page and the 1 MB
page with guard v2. Guard v2 settles on the kernel GC (see `SPEC.md`,
"Limits and graceful failure").

`<BASE>` is the raw URL of the repository source. Use the version path
`releases/0.0.4a/`, not `releases/latest`.

## 1. Install

No reboot is needed. Since 0.0.3a, `html` clears the cached `html.*`
modules, so the new guard loads on the next run.

```
wget -f <BASE>/releases/0.0.4a/html-install.lua /home/html-install.lua
/home/html-install.lua
```

- The installer prints `html-install: oc-html 0.0.4a`, one line per file with
  its size, and `installed 6 files`.
- If it stops, it prints one line that starts with `html-install: `. The old
  files stay in place.

Check: `html --help` shows the usage.

## 2. Run html

The pages are the same as in Task 3c. If they are missing, fetch them again:

```
wget -f <BASE>/tests/pages/large.html /home/large.html
wget -f "https://en.wikipedia.org/wiki/Lua_(programming_language)" /home/wiki.html
```

Then run:

```
html --stats --stats-out /home/stats-wiki.txt /home/wiki.html > /dev/null
html --stats --stats-out /home/stats-large.txt /home/large.html > /dev/null
```

- The stats must not end with a crash. A missing value prints as `n/a`.
- The new line `stats: settles=<n> gc_seen=<n> settle_yields=<n>` follows
  `peak_used`.
- In `stats: trace=`, a sample that ends with `s` is a settle result. A
  sample that ends with `S` is a settle result that saw a GC.

## 3. What to paste back

1. `cat /home/stats-wiki.txt`
2. `cat /home/stats-large.txt`
3. The installer output of step 1.
4. Any error text, exactly as shown. If the error mentions
   `/tmp/html-error.log`, also paste `cat /tmp/html-error.log`.

## 4. Expected result

- The wiki page renders fully (182 lines at width 160). `settles` is small,
  probably 1 (the `free_after` settle) or a few.
- `large.html` stops at about 4000 to 9000 lines with
  `html: page too large for available memory (rendered N lines before stopping)`,
  or it renders fully (11302 lines in the container). 0.0.3a stopped at 1803
  lines.
- When it stops, the last trace sample is a settle result, for example
  `5000:150000S`. Its value is under 196608 (the 192 KB reserve).
- `gc_seen` is usually equal to `settles`. A settle sees no GC when the GC
  frees less than 16 KB, or when the kernel did not run its GC within 11
  yields. If `gc_seen` is 0 with several settles, report it.
- `settle_yields` is at most 11 per settle, about 10 ms each.
