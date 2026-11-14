# Installer

Source: `tools/installer.lua` (template), `tools/mkinstall.lua` (generator). Output: `releases/<version>/html-install.lua`. Index: `SPEC.md`. Releases: `spec/release.md`.

`html-install.lua` installs a release with one fetch. It needs no data card and no other script.

```
wget -f <BASE>/releases/<version>/html-install.lua /home/html-install.lua
/home/html-install.lua [--prefix <dir>] [--dry-run]
```

## Behavior

- The default prefix is `/home`. It writes `<prefix>/bin/html.lua` and `<prefix>/lib/html/*.lua`, and creates the folders.
- A relative `--prefix` is resolved against the current directory (`shell.resolve`).
- `--dry-run` runs the checks and lists the files. It writes nothing.
- Output: `html-install: oc-html <version>`, one line `<path> <size> bytes` per file, then `installed N files`.
- Checks before any write:
  - each embedded file has the size recorded at build time (a short download fails here or as a syntax error),
  - no target path is a directory,
  - the target filesystem (`filesystem.get(path)`) is not read-only,
  - free space (`spaceTotal() - spaceUsed()`) is at least the sum of the file sizes, plus the largest file (for the temporary copy), plus 1024 bytes per file. Old files that the install replaces are not counted.
- Write order:
  1. Each file goes to `<target>.new` in the target folder. The installer reads it back and compares it with the embedded content.
  2. When all temporary files are correct, each old file moves to `<target>.old`, and `<target>.new` is renamed to `<target>`. Rename over an existing file replaces it (measured on tmpfs and on the HDD). The move-aside step is kept as a safe rollback.
  3. The `.old` files are removed.
- On a failure before the first write (a failed check), the installer prints one line `html-install: <reason>`. It wrote nothing, so the line has no suffix.
- On a failure after writing has started, the installer removes its temporary files, puts the old files back, and prints one line `html-install: <reason>; old files kept`.
- An unexpected error also prints one `html-install: ` line.
- The exit code is 1 (2 for bad arguments).
- Loaded with a table as the first argument, the chunk returns its module: `VERSION`, `files` (relative path to content), `sizes` and `main(argv, deps)`. The tests use this with a fake filesystem.

## How it is built

- `tools/installer.lua` is the template with the install logic. `tools/mkinstall.lua` replaces its `-- @@FILES@@` line with the version and one long-bracket string per file in `files.txt`.
- The long-bracket level is the lowest level whose close bracket first appears at the end of `content .. close`. Lua drops a newline right after the opening bracket, so the generator always writes one there.
- The generator refuses content with a carriage return (Lua turns `\r` and `\r\n` in a long string into `\n`), bad or duplicate paths, and a bad version. It loads the result and compares every file before it prints the source.
- `release.ps1` runs the generator in the test container (sandbox flags, repository read-only) and redirects stdout to the file. Then it runs `luac5.3 -p` on the installer and `lua5.3 tools/mkinstall.lua --check <version> releases/<version>`, which compares the embedded files with `files.txt` and the release copies.
