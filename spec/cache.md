# Disk page cache

Source: `lib/html/cache.lua`. Index: `SPEC.md`. Tests: `tests/cache_test.lua`.

Status: design approved by the user. The module and the wiring in `bin/html.lua` (`run_session`, `load_page`) are built.

Goal: a page fetched in this session is stored on disk. Back, Forward, the load of the previous page after an abort (`prev`) and history re-visits read the stored copy. Reload bypasses it and replaces the copy. A new link or go always fetches. The memory holds an index only.

## Scope

- Print mode and the no-screen path do not use the cache.
- Local files are not cached. Only keys that start with `http://` or `https://` are stored.
- Two html instances at once are not supported. They share the folder, and the start and exit cleanup of one deletes the files of the other.

## Folder

- The folder is `/home/.cache/html/`. The path is the `dir` option, and this value is the default.
- The cache does not use `/tmp`. The OpenOS tmpfs is about 64 KB.
- `cache.new` makes the folder when it is missing. It never runs component calls at load time. All filesystem calls come from `deps` (`get`, `exists`, `makeDirectory`, `remove`, `rename`, `list`, `open`), so the tests pass a fake.

## Budget

Taken once, at session start, after the leftovers are deleted.

- `free` = `proxy.spaceTotal() - proxy.spaceUsed()`, where `proxy` is the first result of `filesystem.get(dir)`.
- `bytes_cap` = min(25% of `free`, 2 MiB, `free` - reserve). The reserve is 64 KB of free space that the cache never uses.
- `entries_cap` = 16.
- When `proxy.isReadOnly()` is true, or `bytes_cap` is under 1, the cache is off for the session.

## Content and index

- The content is the bytes that the page reader returns, after any charset step. A cached page replays through the local-file source path.
- The index maps a key to `{ file, bytes, final_url, status, content_type, is_error, last_used }`. `last_used` is a counter, not a clock.
- The key is the requested URL without its fragment (`cache.key`). The final URL after a redirect is stored in the entry, not used as the key.
- A new page for a known key replaces the old entry.

## Storing

- `cache.begin(key)` returns a writer. The loader calls `w.write(chunk)` for each chunk. The body is never held in memory.
- The writer writes to `<n>.part`. `w.commit_complete(meta)` renames it to `<n>` and adds the entry. `w.abort()` deletes the `.part` file. A page that is not complete is never an entry.
- A page larger than `bytes_cap` is not cached. `write` returns false when the size passes the cap, and the writer deletes the part file. The cache stays on.
- Eviction is LRU (least recently used, by `last_used`). It runs before each new entry for the entry count, and while writing for the byte total. Each `get` that hits updates `last_used`.

## Wiring

- `run_session` makes the cache once per session from `deps.cache` (the filesystem links, built in `game_deps`). Without `deps.cache` nothing is cached.
- A remote load stores a page only for a 2xx status. A load that is aborted, broken, short or failed calls `w.abort()`. The load calls `w.commit_complete` when the render ends and the stop check passes.
- A cached page loads through the local-file source path. Its location is the final URL of the entry, else the requested URL, so the links and `<base>` resolve against the URL. A read error in `get` or `open()` drops the entry and the page is fetched. A read error during the read of a cached page gives a broken page and drops the entry, and Reload fetches.
- `main` calls `cache.clear()` where it restores the screen, so every exit (quit, Ctrl+C, an error) empties the folder.

## Lookup

- `cache.get(key)` returns an entry with `open()` (a file handle for reading), or nil.
- A read error, in `get` or in `open()`, drops the entry. `get` returns nil. A caller that sees a read error later calls `cache.drop(key)`.

## Failure

- Any write, close (flush), rename or space error, or a read-only disk, turns the cache off for the rest of the session. The cache deletes its files. It shows no popup. The loader and the viewer keep working: `begin` returns nil, `get` returns nil, and a writer in flight returns false.
- A handle call fails when it raises, or returns nil or false with a reason. A bare nil or no values is success: OpenOS `close()` returns nothing on success, and `write` returns the handle.
- The cache never raises into the caller.

## Cleanup

- `cache.clear()` deletes the content of the folder and empties the index. Writers in flight stop.
- `cache.new` calls it at session start, which removes the leftovers of a crash. The program calls it on every exit.
