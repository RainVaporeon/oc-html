# Browser tabs

Source: `bin/html.lua` (session loop), `lib/html/tabs.lua` (the tab list, pure), `lib/html/history.lua`, `lib/html/viewer.lua` (keys, status line). Index: `SPEC.md`. Keys and prompts: `spec/viewer.md`. Loads and history: `spec/navigation.md`. Reasons: `docs/rationale.md` "Tabs drop the document".

Status: roadmap item 0.7.0a, spec written, waiting for the user's approval. The user decided on 2026-11-17: a tab switch or `!` during a load stops the load (the `pending` rule below). The user revised the spec on 2026-11-17: `c` asks for a confirmation, Ctrl+S (not `d`) starts a download, and the experimental option `--tabs` sets the tab limit. Background loads are planned for 0.7.1a (`spec/background.md`).

Doc rules: Minecraft catches Esc in game and removes focus from the screen, so no tab feature uses Esc. A blank Enter cancels each prompt.

## Keys

The new keys are lowercase only, like `g`. The uppercase letters stay free for later versions.

| Key | Char | Action |
|---|---|---|
| `t` | 116 | New tab: with the selected link, or with a prompt. |
| `c` | 99 | Close the current tab, after a confirmation. |
| `<` | 60 | Previous tab (wraps). |
| `>` | 62 | Next tab (wraps). |
| `!` | 33 | Shell tab-out (`spec/shell.md`). |
| Ctrl+S | 19 | Download (`spec/download.md`). |

- No new key collides with an existing key. `classify` tests char 3 (Ctrl+C) before it tests other chars, so `c` (char 99) is safe. Ctrl+S is char 19, so it does not collide with Ctrl+C (char 3). The rules to detect Ctrl+S are in `spec/download.md` "Key". The key `d` stays free.
- `classify` uses the char value, so Shift does not matter for `<`, `>` and `!`.
- The choices follow known text browsers: `<`, `>` and `c` from `links`; `!` from less, vi and lynx; Ctrl+S is the common "save" key.
- The digit keys do not switch tabs. NumPad digits with NumLock on send the chars `1` to `9`, and a NumPad digit must not act as a navigation key (`spec/viewer.md` "Keys").
- The key list popup and the `--help` text list the new keys (`spec/viewer.md` "Navigation keys", `spec/cli.md`).

## Behavior

- A session starts with 1 tab. The limit is 8 tabs, or the value of the experimental option `--tabs` (see "Tab limit option (experimental)" and "Tab state model").
- `t` with a visible selected link. The link resolves as it does for Enter.
  - The link loads like Enter in phase 1: the current tab stays active and its page stays on screen (`had` is true, as for a `link` load). The new tab opens at the commit, when the first response is known to be a page. It opens directly after the current tab and becomes the active tab. The departing tab keeps its state with the rules of "A load at a tab switch or at `!`". The new tab has a new, empty history, and the commit pushes the entry.
  - Before the commit, no tab exists. A phase 1 failure shows the popup over the current page, and no tab opens. `z`, Left and Backspace abort as for a `link` load, and no tab opens. A leave action (`<`, `>`, `c`, `g`, another `t`, `!`) stops the load, and no tab opens and nothing stays as `pending`.
  - A same-document link (`#fragment`) opens a tab with the current page URL and that fragment. The load can use the cache.
  - A link that does not resolve shows its popup. A link with an unsupported scheme shows `<scheme>: links are not supported`. A link stored as false shows `link too long`. In these cases no tab opens.
- `t` with no visible selected link. The status row shows the prompt ` New tab: ` (the prompt of `spec/viewer.md` "Status-row prompt").
  - Typing follows the go prompt rules: printable ASCII 0x20 to 0x7E adds a character, Backspace deletes one character, and a clipboard event adds its text. The input cursor is a reverse-video cell at the end of the text.
  - A blank Enter cancels.
  - The submitted text uses the CLI classification (local path, URL, or guessed URL). A bad entry shows a popup, and no tab opens.
- `t` with as many open tabs as the limit. The status notice `tab limit: <n> tabs` shows until the next key (`<n>` is the limit). Nothing opens.
- `t` with the option `--tabs` (a number or `auto`) and low memory. See "Tab limit option (experimental)": the notice `not enough memory for a new tab` shows, and nothing opens.
- `t` with a link that leads to a file download (`spec/download.md` "Link to a file"). No tab opens: the save prompt opens over the current page, and the history does not change.
- `t` while the current tab loads. The load of the current tab stops first, with the rules of a leave action. Only the limit checks come before the stop.
- `<` and `>` select the previous or the next tab, and the order wraps. With 1 tab they do nothing.
- `c` asks for a confirmation, then closes the current tab. There is no undo.
  - The status row shows the prompt ` Close tab? (y/n)`. The answer rules are those of the quit prompt (`spec/viewer.md` "Quit"): `y`, `Y` or Enter confirms. Any other key cancels. A `key_up` event does not answer. Ctrl+C exits at once. A "no" does nothing: the tab, its page and its load stay as they were.
  - A load in the tab goes on while the prompt shows, as for the quit prompt. The load stops only after the user confirms (see "A load at a tab switch or at `!`").
  - The tab to the right becomes active. When there is none, the tab to the left becomes active.
  - On the last tab, `c` shows the notice `last tab: q quits` and no prompt, and does nothing else.
  - The closed tab's history and pending load are dropped.
- Status line. When 2 or more tabs are open, the left part has the prefix `[<i>/<n>] `, for example `[2/3] Example Domain`.
  - The prefix also comes before `-> <url>`, before the loading texts and before `[error]` and `[aborted]`.
  - A notice replaces the whole left part, including the prefix.
  - `TITLE_MIN` (20 columns) counts the prefix.
  - The hint on the right does not change.
- Quit prompt. With 2 or more tabs, the text is ` Quit and close <n> tabs? (y/n)`. With 1 tab, it stays ` Quit? (y/n)`. The answer keys do not change (`spec/viewer.md` "Quit").
- During a download the tab keys show a notice and do nothing else (`spec/download.md` "Progress, keys and end").

## Showing a tab

This applies to a switch, a close, and the return from the shell.

- The arriving tab shows at once with an empty page and the status `[i/n] Loading <name>...`. Then it does the first item of this list that applies:
  1. The tab has `pending`: the pending load starts again ("A load at a tab switch or at `!`").
  2. The tab has `shown` (a broken or aborted page): the empty page shows with the status `[error] <target>` or `[aborted] <target>`. No popup shows and nothing loads. `r` reloads it.
  3. Otherwise the tab loads its current history entry with the mode `switch`.
- After the load, `top` and `sel` come from the history entry. They are clamped to the new line and link counts, as for Back and Forward (`spec/navigation.md` "History").

## The load mode `switch`

- It loads the current history entry of the arriving tab.
- `had` is false: no old page is on screen in phase 1.
- `replay` is true: the program uses the cached copy when the disk cache has one, else it fetches (`spec/cache.md`).
- `on_commit` changes no history entry.
- A phase 1 failure shows the broken page and the popup in that tab, and the history does not change. An error after the commit also gives the broken page.
- `z` during a `switch` load shows the empty page with `[aborted] <target>`, and the entry stays. This is the rule for an abort of a reload, back or forward (`spec/navigation.md` "Abort"). `r` reloads it.

## Tab state model

Each tab is a record of plain data, so `serialization.serialize` can store it (needed by 0.8.0a):

```
tab = {
  entries = { { target = <URL or absolute path>, top = <int>, sel = <int or nil> }, ... },  -- up to 32
  pos     = <int>,                        -- the current history index
  guesses = { [target] = <typed arg> },   -- keeps the " (no local file named <arg>)" suffix
  shown   = nil | { kind = "broken" | "aborted", name = <string>, target = <key of the current page, or nil> },
  pending = nil | { target = <string>, mode = "first" | "link" | "go" | "back"
                    | "forward" | "reload", fragment = <string or nil>,
                    top = <int or nil>, sel = <int or nil>, arg = <string or nil> },
  job     = nil,                          -- reserved for 0.7.1a. Always nil in 0.7.0a.
}
tabs snapshot = { v = 1, active = <int>, list = { tab, ... } }
```

- `lib/html/history.lua` gets two functions. `h.export()` returns `{ entries = <copy>, pos = <int> }`. `history.import(data, cap)` returns a history object. The module stays pure.
- `lib/html/tabs.lua` is a pure module with no `component` calls. It holds the tab list and the active index: `new(cap)`, `add_after`, `close`, `next` and `prev` with wrap, `active`, `count`, `snapshot` and `restore`.
- The active tab also holds the live objects that `run_session` holds today: `held` (lines, links, anchors, base, resolve), `cur`, `top`, `sel`, `popup` and the loader `bg`.
- An inactive tab keeps only the record above. It drops the rendered document (lines, link spans and hrefs, anchors, base, resolve closures). It never holds a loader or a card handle.
- Each time a tab shows, the program renders its page again.

Why the program renders the page again (`docs/probe/FACTS.md`):
- A line costs about 66.5 scaled units. The 1 MB page (11302 lines) used about 750 K of about 1.8 MB free. The fixed overhead is about 280 K. So two kept documents can fill 2 MiB.
- A render from the disk cache is fast. The render speed is about 630 KB/s of CPU, and a file read is 320 to 430 KB/s. A Wikipedia page (182 lines) takes about 0.13 s.

Why the limit is 8 tabs:
- A history entry costs about 150 scaled units (a table of about 61 plus a URL of about 100 bytes). A full history of 32 entries costs about 5 K, so 8 tabs cost about 40 K (about 2% of 2 MiB).
- The worst case is 32 URLs of 2048 bytes: about 37 K per tab, about 300 K for 8 tabs. This is still bounded, and the size check at each commit measures the memory after the release of the old page.
- The cache has 16 entries, which is about 2 per tab.
- The prefix `[8/8] ` stays short.
- A limit that scales with the memory is the experimental option `--tabs auto` (next section). The default stays 8.

The cache does not pin pages. The LRU order can evict the page of an inactive tab, and the next show then fetches it.

## Tab limit option (experimental)

The option `--tabs <X|auto>` (`spec/cli.md`) is experimental. It can change or go away in a later release, and the formula below is a first guess that the in-game check must confirm.

- Without `--tabs`: the limit is 8, and `t` makes no memory check.
- `--tabs X`: `X` is an integer from 1 to 32. The limit is `X`. Any other value is a usage error: `html: --tabs needs a number from 1 to 32, or auto` (`spec/cli.md`).
- `--tabs auto`: the program computes the limit once at start, with `settled_free` from `guard.settled_free()` read before the first page loads:
  ```
  limit = floor((settled_free - MEMORY_RESERVE - page_budget) / TAB_COST)
  page_budget = (settled_free - MEMORY_RESERVE) / 2
  ```
  The result is clamped to 1 to 32.
  - `MEMORY_RESERVE` is the constant of `lib/html/guard.lua` (192 KB in `freeMemory()` units, `spec/guard.md` "Memory reserve"). `guard.lua` exports it as `guard.MEMORY_RESERVE`, read only, so `bin/html.lua` uses the one value. All numbers are scaled units, as `freeMemory()` gives them.
  - `page_budget` is half of what is free above the reserve. It keeps room for one rendered page, because a tab keeps no document and only the active tab renders one ("Tab state model").
  - `TAB_COST` is 40 K scaled units. Reason: a full history of 32 entries with 2048-byte URLs costs about 37 K ("Why the limit is 8 tabs"), and the 40 K covers the rest of the record.
  - Example, not measured: `settled_free` 1400 K gives (1400 - 192 - 604) / 40 = 15 tabs.
- With `--tabs` (a number or `auto`), each `t` also checks the memory before it opens a tab. When `guard.settled_free()` is under `MEMORY_RESERVE + TAB_COST`, `t` shows the notice `not enough memory for a new tab` until the next key and opens nothing. The check comes after the limit check and after the link resolves. The settle can take up to about 110 ms (`spec/guard.md` "Settle").
- The notice at the limit is `tab limit: <n> tabs`, with the limit of the session.
- The in-game check records the `auto` limit on 1 and on 2 sticks of tier 3 memory, then opens tabs up to the limit with Wikipedia pages and records the free memory (`tasks/todo.md` 0.7.0a, in-game checklist). Reasons for the formula: `docs/rationale.md` "Tabs drop the document".

## A load at a tab switch or at `!`

Each of these actions stops a load that runs: `<`, `>`, `t` (after the link resolves, or after the prompt text is submitted), `c` (after the user answers `y` or Enter at ` Close tab? (y/n)`), and `!`. They use the leave-action rules of `spec/navigation.md` "During a load". The loop closes the handle, ends the coroutine and aborts the cache writer. At any time, at most one load or one download runs, and at most one card connection is open.

- Stop before the commit (phase 1). The departing tab keeps the old page entry. The tab also keeps the stopped load as `pending`, with its target, mode, fragment, `top`, `sel` and arg.
  - A Back or Forward that the switch stops keeps its history index move, so the pending load loads the target entry.
  - A `first` load keeps `pending` too (the load of the start argument). Its history is empty, so the commit of the pending load pushes the entry. The load of a `t` is not kept: its tab does not exist before the commit, so a stop in phase 1 drops it.
- Return to a tab with `pending`. The program starts the pending load with its mode, and then clears `pending`.
  - A `link` or `go` load pushes its entry at the commit. A `reload` fetches. A `back` or `forward` uses the cache first.
  - A phase 1 failure of a pending load shows the popup. Then the tab loads its current history entry with the mode `switch`. When the history is empty, the broken page shows instead.
- Stop after the commit. The departing tab keeps the new history entry (the commit appended it), with the `top` and `sel` of that moment. The page did not finish, so it is not in the cache. When the tab shows again, the `switch` load looks in the cache first, finds nothing, and fetches.
- `c` on a tab with a load. The load goes on while the prompt shows. After the user confirms, the load stops and the tab closes with its state. After a "no", the load goes on.
- The departing document. It is released before the arriving tab loads.

## Messages

| Text | Kind |
|---|---|
| `tab limit: <n> tabs` | notice |
| `not enough memory for a new tab` | notice (only with `--tabs`) |
| `last tab: q quits` | notice |
| ` Close tab? (y/n)` | prompt |
| ` New tab: ` | prompt |
| ` Quit and close <n> tabs? (y/n)` | prompt |

The full list of the messages of 0.7.0a is in `spec/errors.md` "Tab, shell and download messages".
