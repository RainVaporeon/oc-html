# Releases

Source: `tools/release.ps1`. Index: `SPEC.md`. Installer: `spec/installer.md`.

A release is a fixed copy of the in-game files.

- Path: `releases/<version>[suffix]/<output>`.
- Version: `major.minor.patch`. Suffix `a` is alpha, `b` is beta, no suffix is a real release.

Release command (from the project root, Docker Desktop running):
```
pwsh tools/release.ps1 0.0.1a
```

The script stops when:
- the version does not match `major.minor.patch` with an optional `a` or `b`,
- `releases/<version>` already exists (a release is never overwritten),
- `bin/` or `lib/` has uncommitted changes (a release always matches a commit),
- `pwsh tests/docker/test.ps1` fails.

Then it copies the files, writes `files.txt`, creates `release.tar.gz` (ustar format, sorted names, owner and group 0, made with the Windows `tar.exe`), creates `html-install.lua` and updates `releases/latest`. It always records the new link in the git index, so git shows `releases/latest` as one staged modification. If a real symlink cannot be created, the link exists in the git index only.

## Layout

Mirrors the in-game paths under `/home`:
```
releases/<version>/bin/html.lua         goes to /home/bin/html.lua
releases/<version>/lib/html/*.lua       goes to /home/lib/html/
releases/<version>/files.txt            one relative path per line, sorted, LF endings
releases/<version>/release.tar.gz       the files in files.txt, same relative paths (gzip, ustar)
releases/<version>/html-install.lua     one-file installer that holds the files in files.txt (from 0.0.2a)
```

- `files.txt` lists the files of the release, not itself. It lists neither `release.tar.gz` nor `html-install.lua`. The installer generator reads it.
- The script checks the tarball: the list equals `files.txt`, and each extracted file is byte-identical to the release copy. It stops with an error if a check fails.

## Tarball only

Add only the tarball to an existing release that has none:
```
pwsh tools/release.ps1 -TarballOnly 0.0.1a
```
`-TarballOnly <version>` runs the same tar command and checks, and changes no other file. It stops if `release.tar.gz` already exists.
