# Command line

Source: `bin/html.lua`. Index: `SPEC.md`.

## Usage

In game:
```
html [--print] [--width n] [--no-rescale] <file>
                     render a local HTML file. The viewer is the default
                     (a URL also works: see spec/url.md and spec/fetch.md)
html --print <file>        write the page as text to stdout, without style bytes. The width is the terminal width
html --no-rescale <file>   keep the current screen resolution
html --width n <file>      output width in columns. It turns on --print; use it to compare with test files
html --help          show usage
html                 (no arguments) show usage. Later: start a new session
html ~/page.html     a leading "~/" (or a bare "~") is the home directory
html-install [--prefix <dir>] [--dry-run]
                     install a release from its one-file installer (see spec/installer.md)
```

- `--help` lists the URL forms too, and the keys of the viewer: scrolling (`Up Dn PgUp PgDn Home End`), links (`Tab`, `Shift+Tab`, `Enter`), history (`Left` or `Bksp` for back, `Right` for forward), `g` go to, `r` reload, `z` abort a load, `?` key list, `q` quit.
- The URL fragment of the argument (`html http://host/page#top`) is kept. After the first load, the viewer jumps to its anchor (`spec/navigation.md` "Same-document links"). An unknown fragment stays at the first `top`. A local file argument takes no fragment.
- Every usage error (an unknown option, too many arguments, a bad `--width`) prints one line to stderr that ends with ` (see html --help)`, and exits with code 2.
- A URL argument and an argument without a scheme follow `spec/url.md`.
- Exit codes for a URL. In the viewer, a fetch error after the frame opened and a read error of the body, a timeout in the body and a memory stop show a popup and keep the session: the exit code is 0 when the user quits (`spec/loading.md` "Errors after the frame"). In print mode, with no screen, and for an error before the frame, the line goes to stderr, and no part of a broken page prints and the exit codes stay: 1 for an error, 2 for a bad argument, 130 for Ctrl+C. An HTTP error status that `fetch.open` maps (`spec/fetch.md` "HTTP error statuses") exits with 0 in every mode.

## Home directory

- `shell.resolve` does not expand `~` (see `docs/rationale.md` "Commands"). So `bin/html.lua` replaces a leading `~/` or a bare `~` in the file argument with the home directory before `shell.resolve`. The home directory is `os.getenv("HOME")`, or `/home` when it is not set. `~user` is not expanded.

## Output width

- The viewer width is the screen width after the resolution step (see `spec/viewer.md` "Resolution").
- `--print` uses the terminal width. `--width n` sets the width and turns on `--print`.
- The widest output line is the width minus 1 columns. The last column stays empty. This applies to the viewer and to print mode. Example: `--width 20` gives lines of at most 19 columns.
- `--width` accepts a whole number from 2 to the maximum. The minimum is 2 because the widest line is the width minus 1, so width 2 gives lines of 1 column. The maximum is the width of `gpu.maxResolution()` of the GPU and screen in use. With no GPU or no screen, the maximum is 160 (the tier 3 maximum).
- Any other `--width` value is a usage error: `html: --width needs a whole number from 2 to <maximum>`, exit code 2.

## Local files

- The checks before the TUI opens: the arguments, then whether the file exists and is a file (see `spec/loading.md` "Startup").
- A missing local file gives `html: file not found: <file>`, exit code 1. This is the only message for a missing file, also when the open itself fails because the file is missing.
- A directory gives `html: not a file: <file>`, exit code 1.
- A read error on a local file after the frame opened is a broken page: the viewer shows a popup over an empty page and the exit code is 0 on a normal quit (`spec/loading.md` "Errors after the frame"). In print mode and with no screen, the program prints no text, one line `html: read error: <reason>` goes to stderr, and the exit code is 1. A file that exists but cannot be opened (the reason is the open error, for example `permission denied`) gives the same line and exit code 1 before the frame.
- An empty file shows an empty page. In `--print` mode, it writes nothing.
- With no GPU or no screen, the program falls back to print mode and writes one line to stderr. It does not open the TUI.

## Output streams

- The page text goes to stdout in print mode. Errors and notices go to stderr.

## Print output loop

- The print output loop has no memory check. It keeps no new data. It yields and checks Ctrl+C.
- Print mode renders all lines first, with the guard and the size check of `spec/guard.md`, as in the viewer. Then it writes them.
