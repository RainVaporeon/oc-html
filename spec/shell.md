# Shell tab-out

Source: `bin/html.lua` (session loop, `main`, `game_deps`), `lib/html/viewer.lua` (`open`, `session.close`). Index: `SPEC.md`. Tabs: `spec/tabs.md`. Reasons: `docs/rationale.md` "Shell tab-out is a nested shell".

Status: roadmap item 0.7.0a, spec written, waiting for the user's approval. In 0.7.0a a load that runs stops at `!` (the `pending` rule of `spec/tabs.md`). The user decided on 2026-11-17 that background loads pause during the shell. That is 0.7.1a (`spec/background.md` "Shell tab-out").

## Behavior

- `!` leaves the viewer and starts a nested OpenOS shell. `exit` returns to the browser.
- After the return, all tabs, the active tab, the histories and the scroll positions are the same as before. The active tab shows again with the rules of `spec/tabs.md` "Showing a tab", at the new screen width.
- A load that runs stops first (`spec/tabs.md` "A load at a tab switch or at `!`").
- `!` during a download shows the notice `download running: z stops it`, and the shell does not start (`spec/download.md`).
- Inside the tab-out shell, a nested `html` refuses to start. It prints `html: already open; type exit to return to it` and exits with code 1. Reason: two instances share the cache folder, and the start and exit cleanup of one deletes the files of the other (`spec/cache.md` "Scope").

## Sequence

1. Stop the load that runs, with the rules of `spec/tabs.md`. Write `top` and `sel` into the active tab's history entry. Drop `held`.
2. Call `ctx.session.close()`. This restores the resolution and the colors from when the viewer opened, calls `term.clear()` and sets the cursor (`spec/viewer.md` "Exit").
3. Set the cursor to (1, 1) (an optional dep `home_cursor`, `term.setCursor`). Print one line on stdout and flush stdout: `html: shell started. Type exit to return to the browser.`
4. Call `os.setenv("HTML_TABOUT", "1")`, then `pcall(deps.shell)`, then `os.setenv("HTML_TABOUT", nil)`. In `game_deps`, `deps.shell` is `function() return shell.execute("sh") end`.
5. Call `deps.open_screen{ no_rescale = opts.no_rescale, status = "Returning..." }`. The new session saves the screen state of that moment, so a change that the user made in the shell (for example `resolution`) is the state that the final exit restores. Compute the layout width again with `screen_width`.
6. Pull and drop the queued events with `pull(0)`, up to 64 events. Set `enter_held = true` (a new option of `viewer.open`). Then the `key_up` of the Enter that typed `exit` cannot follow a link, and a stale "interrupted" event cannot end the program.
7. Show the active tab with the rules of `spec/tabs.md` "Showing a tab".

`main` reads `os.getenv("HTML_TABOUT")` before the TUI opens. When the value is set, it refuses with the message of "Behavior".

## Errors

- An error in the shell call (pcall returns false): the browser returns and shows the popup `html: shell error: <reason>`.
- The screen cannot open again (for example, the GPU has no screen): the program ends with `html: cannot reopen the screen: <reason>` and exit code 1. `main` clears the cache, as on every exit.

## Risks

- Memory. The html process stays in memory while the shell runs: the modules (about 280 K fixed overhead) and the tab records. The document is dropped, so the shell has about 1.4 MB. The program does not unload the `html.*` modules, because `run_session` holds them as locals.
- GPU state. The user can change the resolution, the depth, the palette or the screen binding. The new session reads the depth and the resolution again, and the render uses the new width. The colors are RGB values. A changed palette at depth 4 can shift the colors, and this is accepted.
- Event queue. The shell reads the keys while it runs. Step 6 drops the queued events that remain. The program has no listener during the shell, because `deps.on_interrupt` is registered only while a load runs, and the stop removes it.
- Ctrl+C in the nested shell. It must not end html. The pcall guards the call. Check this in game.
- Environment. It is not verified that a child process of OpenOS 1.8.9 inherits a variable set with `os.setenv`. Check this in game. If it does not work, use a marker field in a table in `package.loaded` instead. That is a weaker guard.
- Cache. The cache folder stays during the shell. If the user deletes files in it, the next read of a missing file drops its entry and the page is fetched.
