# In-game check: Task 3c (release 0.0.3a, module cache and memory trace)

Goal: install 0.0.3a, measure the module cache and the memory limit with
`tools/memprobe.lua`, and get the memory trace of the Wikipedia page and the
1 MB page.

`<BASE>` is the raw URL of the repository source. Use the version path
`releases/0.0.3a/`, not `releases/latest`.

## 1. Reboot first

Run `reboot`. This removes the old `html.*` modules from memory. 0.0.2a
crashed because the 0.0.1a guard was still loaded.

## 2. Install

```
wget -f <BASE>/releases/0.0.3a/html-install.lua /home/html-install.lua
/home/html-install.lua
```

- The installer prints `html-install: oc-html 0.0.3a`, one line per file with
  its size, and `installed 6 files`.
- If it stops, it prints one line that starts with `html-install: `. The old
  files stay in place.

Check: `html --help` shows the usage.

## 3. Run memprobe

memprobe is not part of the release. Fetch it from `tools/`:

```
wget -f <BASE>/tools/memprobe.lua /home/memprobe.lua
/home/memprobe.lua --step 1
/home/memprobe.lua --step 2
```

- Run step 2 right after step 1. Do NOT reboot between the steps. Step 1
  stores a marker in `package.loaded`. Step 2 checks if the marker is still
  there.
- Each step prints `memprobe: step N done, ... lines in /home/memprobe.txt`
  and what to do next.
- Step 2 makes about 600 KB of garbage and then asks for one string larger
  than the free memory. It can print nothing for a few seconds. A
  "not enough memory" value in the report is a valid result.
- If memprobe cannot write the file, it prints the report lines on the
  screen. Copy them.

## 4. Run html

The pages are the same as in Task 3b. If they are missing, fetch them again:

```
wget -f <BASE>/tests/pages/large.html /home/large.html
wget -f "https://en.wikipedia.org/wiki/Lua_(programming_language)" /home/wiki.html
```

Then run:

```
html --stats --stats-out /home/stats-wiki.txt /home/wiki.html > /dev/null
html --stats --stats-out /home/stats-large.txt /home/large.html > /dev/null
```

- `large.html` may stop with
  `html: page too large for available memory (rendered N lines before stopping)`.
  That is a valid result. The stats file then ends with a `stats: stopped=`
  line.
- The stats must not end with a crash. A missing value prints as `n/a`.
- The new line `stats: trace=<line>:<free>,...` holds up to 64 free memory
  readings across the run.

## 5. What to paste back

1. `cat /home/memprobe.txt`
2. `cat /home/stats-wiki.txt`
3. `cat /home/stats-large.txt`
4. The installer output of step 2.
5. Any error text, exactly as shown. If the error mentions
   `/tmp/html-error.log`, also paste `cat /tmp/html-error.log`.

## 6. How to read the results

- `h1.result=kept` means OpenOS keeps a module table between two program
  runs until a reboot (H1).
- `h2.tryN.ok=true` with `h2.tryN.size` larger than `h2.tryN.free_before`
  means the allocation got memory that `freeMemory()` did not show as free:
  garbage that a full GC removed, or the `ramScale` factor (H2). See
  `docs/probe/FACTS.md`, "Module cache and memory limit".
- `h2.after_yields` holds 20 readings, one after each yield. A jump shows
  when the kernel ran a full GC.
- In the container, `large.html` gives 11302 lines at width 160.
