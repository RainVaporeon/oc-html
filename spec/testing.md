# Testing

Source: `tests/`, `tests/docker/`. Index: `SPEC.md`. Test coverage: `docs/testing.md`.

## Commands

On the host (from the project root, Docker Desktop running):
```
docker build -t oc-html-test tests/docker      build the test image (once, or after a Dockerfile change)
pwsh tests/docker/test.ps1                     run all unit and corpus tests
pwsh tests/docker/test.ps1 fuzz 1000           run 1000 fuzz documents through the pipeline
```

Inside the container, the script runs `lua5.3 tests/run.lua` and `lua5.3 tests/fuzz.lua <n>`.

## Environment

- Lua 5.3 in a Docker container runs the automated tests. Tests replace OpenOS libraries with small shims.
- All automated tests run in Docker. Shims in `tests/shim/` replace `computer`, `unicode` and other OpenOS libraries. The `computer` shim can simulate low memory and `freeMemory()` jitter.
- The shims copy the measured behavior in `docs/probe/FACTS.md` exactly, including the `unicode.*` results for invalid bytes, surrogates and U+200B.
- The fake internet card (`tests/shim/internet.lua`) copies the measured card facts: callable-table methods, a limit of 4 connections, `response()` nil until `finishConnect()` returned true, and the 4xx and 5xx failure texts of `finishConnect` (`docs/probe/FACTS.md` "Internet card (netprobe v1)"). A script option that is not seen in game (`response_early`, `response_after_read`, `response_polls`) says so in the shim header.
- The shim `os.sleep` drops events as OpenOS does. OpenOS `os.sleep` pulls and discards every event that arrives during the sleep (`boot/02_os.lua`). The env `os.sleep` removes the queued events of the `event` shim (`tests/shim/event.lua`, `event.test.push`) and gives each one to the listeners that `event.listen` registered. `event.pull` then returns nothing for them. A test that calls `deps.pull` directly does not use this queue.
- The sandbox env has no `collectgarbage`, like the game.
- The runner helper `t.load_tool(name)` loads `tools/<name>.lua` the same way. `t.read_repo(path)` reads a file under `releases/<version>/` or `tools/` (read-only, no `..`). `t.release_versions()` lists the release folders. `t.list_cases()` lists the base names of `tests/cases/*.html`, sorted. The env `io.open` limit stays as it is. The user approved these helpers.
- All tests run with `--network none`. No test touches a real network. A fake internet card in `tests/shim/internet.lua` serves the fetch tests.

A test pins the probe seams listed in `spec/probe.md`.

## Fakes for tabs, shell and download (0.7.0a)

- The fake shell dep. `deps.shell` in a test is a function that records the call and can raise an error. A test checks that `!` closes the screen, calls the fake shell and opens the screen again, that the same tab and `top` come back, that a shell error shows the popup `html: shell error: <reason>`, and that a nested start (`HTML_TABOUT` set) refuses (`spec/shell.md`). The fake `os.getenv` and `os.setenv` come from `deps`.
- The fake filesystem write links. `lib/html/download.lua` makes no `component` calls. A test gives it fake `open`, `space`, `remove`, `rename`, `exists`, `is_dir` and `cwd` links, so it can check the part file, a full-disk error at `flush` or `close`, the disk-space checks, an existing target after a failure, and no part file after a stop or an error (`spec/download.md`).
- The fake internet card serves a binary file for the `raw` option (`image/png` is accepted, with no Latin-1 step) and counts the requests, so a test can check that a tab switch with a cache hit makes no request (`spec/tabs.md`).
- Tests cover only user-facing behavior (keys, navigation), and only a few are added (`AGENTS.md` "testing").

## Sandbox

Two layers protect the host.

Container (`tests/docker/test.ps1` passes these flags):
- `--rm --network none --read-only`
- `--cap-drop ALL --security-opt no-new-privileges --user 1000:1000`
- `--memory 256m --pids-limit 64`
- The repository is mounted read-only at `/src`. Only `tests/fuzz-failures/` is mounted writable.

Lua environment (`tests/run.lua` and `tests/fuzz.lua`):
- Modules load with `loadfile(path, "t", env)`. Binary chunks are refused.
- `env` has no `os.execute`, `io.popen`, `os.remove`, `os.rename`, `os.exit`, `load` of binary chunks, or `debug`.
- `io.open` in `env` opens files for reading only, and only under `tests/`.

## Success criteria

1. `pwsh tests/docker/test.ps1` passes all unit and corpus tests.
2. `pwsh tests/docker/test.ps1 fuzz 1000` finishes with zero uncontrolled errors.
3. With the low-memory shim, a large page stops with the controlled memory message.
4. In game on tier 3: three saved real-world pages render with readable headings, paragraphs and links, and scroll with all listed keys.
5. In game: a page of about 1 MB does not hit "too long without yielding". It either renders or stops with the controlled memory message. Expect about 10 to 25 s on a 2 MiB machine.
6. In game: `q` shows the prompt. Cancel returns to the page. Quit exits cleanly.
7. In game on a depth-4 and a depth-1 screen: the page renders with the reduced colors or plain text.
8. After any error, the screen colors are normal and the shell prompt is usable, and the original resolution is restored.
