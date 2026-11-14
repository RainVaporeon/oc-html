# Command line

Source: `bin/html.lua`. Index: `SPEC.md`.

## Usage

In game:
```
html [--print] [--width n] [--stats] [--stats-out path] [--no-rescale] <file>
                     render a local HTML file. The viewer is the default
                     (a URL also works: see spec/url.md and spec/fetch.md)
html --print <file>        write the page as text to stdout, without style bytes. The width is the terminal width
html --no-rescale <file>   keep the current screen resolution
html --width n <file>      output width in columns. It turns on --print; use it to compare with test files
html --stats <file>        print the stats lines to stderr (see spec/stats.md)
html --stats-out <path> <file>
                           also write the stats lines to <path> (see spec/stats.md)
html --help          show usage
html                 (no arguments) show usage. Later: start a new session
html ~/page.html     a leading "~/" (or a bare "~") is the home directory
html-install [--prefix <dir>] [--dry-run]
                     install a release from its one-file installer (see spec/installer.md)
```

- `--help` lists the URL forms too.
- A URL argument and an argument without a scheme follow `spec/url.md`.

## Home directory

- `shell.resolve` does not expand `~` (see `docs/rationale.md` "Commands"). So `bin/html.lua` replaces a leading `~/` or a bare `~` in the file argument and in the `--stats-out` path with the home directory before `shell.resolve`. The home directory is `os.getenv("HOME")`, or `/home` when it is not set. `~user` is not expanded.

## Output width

- The viewer width is the screen width after the resolution step (see `spec/viewer.md` "Resolution").
- `--print` uses the terminal width. `--width n` sets the width and turns on `--print`.
- The widest output line is the width minus 1 columns. The last column stays empty. This applies to the viewer and to print mode. Example: `--width 20` gives lines of at most 19 columns.
- `--width` accepts a whole number from 1 to the maximum. The maximum is the width of `gpu.maxResolution()` of the GPU and screen in use. With no GPU or no screen, the maximum is 160 (the tier 3 maximum).
- Any other `--width` value is a usage error: `html: --width needs a whole number from 1 to <maximum>`, exit code 2.

## Local files

- The checks before the TUI opens: the arguments, then whether the file exists and is a file (see `spec/loading.md` "Startup").
- A missing local file gives `html: file not found: <file>`, exit code 1. This is the only message for a missing file, also when the open itself fails because the file is missing.
- A directory gives `html: not a file: <file>`, exit code 1.
- A read error on a local file stops with `html: read error: <reason>`, exit code 1.
- An empty file shows an empty page. In `--print` mode, it writes nothing.
- With no GPU or no screen, the program falls back to print mode and writes one line to stderr. It does not open the TUI.

## Output streams

- The page text goes to stdout in print mode. Errors, notices and `--stats` output go to stderr.
