# Startup and loading screen

Source: `bin/html.lua`, `lib/html/viewer.lua`, `lib/html/guard.lua`. Index: `SPEC.md`. Reasons: `docs/rationale.md` "Startup and loading screen".

## Startup

1. `bin/html.lua` checks the arguments (see `spec/cli.md`). A usage error stops here.
2. For a local file, it checks that the file exists and is a file. For a URL, it checks that the URL is valid (`html.url`). A failed check stops here, before the TUI opens.
3. It opens the TUI at once. It sets the resolution (see `spec/viewer.md` "Resolution"), draws the frame and a status line. This happens before it loads the heavy modules (`tokenizer`, `layout`, `fetch` and their dependencies) and before any network request.
4. It loads the modules, opens the source and renders, in a coroutine that the viewer loop drives (see "Keys during load"). The status line shows the phase.

- This section describes the first load of a session. A later load (a link, Back, Forward, go, reload) reuses the same phases and status texts, with two phases and the commit (`spec/navigation.md` "Two phases of a load"). For a later load, the size check comes after the commit, because the old page must be released before the free memory is measured. On the first load there is no old page. At the commit of a later load, after a last stop check (`z` still aborts in phase 1), the old page leaves and the new, empty live page shows at once (see "Content during load").
- Print mode and the no-screen path do not open the TUI. They keep the order of `spec/cli.md`.
- `html.url` (small, no dependencies) loads during the argument checks for a URL or a missing local path. It parses the URL and decides the host rule. An invalid URL (exit code 2) stops here, before the TUI opens, with no draw call. `html.fetch` loads after the TUI opens, only for a URL.

## Status line during load

- Before the commit (phase 1), the left part of the status line shows the phase. The text is exact:
  - `Loading <name>...` (the file argument or the URL argument, at once)
  - `Loading modules...`
  - `Connecting to <host>...`
  - `Waiting for response...`
  - `Redirect to <url>...`
- After the commit the left part shows `<label> - Loading <n> KB of <m> KB`. The label is the title of the page when it is known (with the `[HTTP <code>] ` prefix of an error status), else the name (the file argument, or the final URL after a redirect). The count rounds up to whole KB. The size is known from the file size or from `Content-Length`. Without a size the text is `Loading <n> KB`, and before the first byte it is `Loading`. A long label is cut, and the `Loading ...` part stays whole.
- The right part is the normal one: the percent and the key hint (`spec/viewer.md` "Status line"). The percent counts the loaded part: `max_top` comes from the lines that are complete so far.
- A selected link that is visible still shows `-> <target>` in place of the left part.
- A phase text, and a new title, show at once. A byte count update is rate-limited to one each 0.25 s. The last update at the end of the input shows the total and is not rate-limited.
- At the end of the load the normal status line returns (title, percent and key hint).

## Content during load

- The load runs as a coroutine, and the viewer loop drives it (see "Keys during load"). The page is usable while it loads: the user can scroll, select links and follow them in the part that is already laid out. Reason: `docs/rationale.md` "Interactive loading".
- The viewer shows a live source: the layout lines, the number of complete lines, the link arrays and the title. A line counts only when it is complete. The lines and the links only grow while the load runs. Only the last link span can still grow, so the viewer reads it again at each pass.
- The viewer loop draws, at each pass, only the rows inside the visible window whose line became complete since the last pass. It does not redraw the rest. A row whose line is not complete shows blank.
- `max_top` uses the number of complete lines at the time of the key. PgDn, Down and End past the loaded part stop at the last complete screen. The page never scrolls by itself: the view stays where the user left it (user decision).
- A link joins the selection list (Tab, Up, Down) when its start line is complete. A link that starts in an unfinished line is not selectable yet.
- Phase 1 of a later load also runs in the coroutine. The old page stays on screen, scrollable and selectable, while the program connects. At the commit the old page is released and the new, empty live page replaces it at once. There is no blank-screen gap.
- A broken page (an error after the commit) shows no part of the page, as in "Errors after the frame": at the end of the load the lines so far are dropped and the popup shows over an empty page.
- When the load ends, the viewer shows the final page with the same `top` and selection. If the user did not scroll or select anything, a URL fragment (or the saved position of Back, Forward and reload) applies as before.

## Keys during load

- The viewer loop owns `event.pull` during a load. Reason: a user coroutine can call the GPU and the card, and `event.pull` and `os.sleep` work there (`docs/probe/FACTS.md` "Coroutines (coprobe v1)"). So the loader never calls `os.sleep`: it yields to the loop, and the loop pulls the events.
  - When the loader yields `wait` (a fetch wait or an empty read), the loop pulls with the timeout of the wait. When it yields `slice` (CPU work, a guard yield, a phase change, or about 0.1 s of work), the loop pulls with timeout 0.
  - The loader yields `commit` once, after phase 1 and the stop check. The loop then releases the old page and shows the live page.
  - Keys are handled at once, from the events that the loop pulls. Only the loop reads events. There is no key listener (`deps.on_key`) and no intent queue: a second source would handle a key twice. The "interrupted" listener (`deps.on_interrupt`) stays: it only sets the stop flag.
- Scroll keys, Tab, Shift+Tab, Up and Down, and the selection work on the loaded part (`spec/viewer.md`).
- Enter on a visible link, `g` (after the user confirms the text), Forward and `r` stop the load first: the loop closes the handle, ends the coroutine and aborts the cache writer. Then the action goes to the session loop as when no load runs (`spec/navigation.md` "During a load"). The page that was left is not cached, so Back to it fetches. Forward at the last history entry does nothing, so it does not stop the load.
  - `g` opens the prompt, and the load goes on while the prompt is open. The load stops when the user submits a text. An empty Enter cancels the prompt (Esc also cancels, but Minecraft catches Esc in game) and the load goes on.
- Keys of 0.7.0a during a load. `<`, `>`, `c`, `!` and `t` (after the link resolves, or after the prompt text is submitted) stop the load and act, with the `pending` rule (`spec/tabs.md` "A load at a tab switch or at `!`", `spec/shell.md`). `t` at the limit of 8 tabs and `c` on the last tab show a notice and the load goes on. `d` shows `wait for the load, or press z` and the load goes on. The prompts of `t` and `d` keep the load going while they are open, as `g` does.
- During a download the loop drives the download job in place of a page load (`spec/download.md`). Only `z` stops it (`spec/viewer.md` "Job kind").
- `z`, `Z`, Backspace and Left (also NumPad Left with char 0) keep the abort meaning (`spec/navigation.md` "Abort"): the load stops and the program goes back as before.
- `q` shows the quit prompt (`spec/viewer.md` "Quit") and loading goes on while it shows. `y`, `Y` or Enter confirms: the load stops and the program exits with code 0. Any other key cancels.
- Ctrl+C during a load exits at once: `html: interrupted`, exit code 130. The loop stops the load first.
- Every exit of the viewer loop while a load runs stops the load first: the handle closes and the guard hooks are restored.
- Print mode and the no-screen path have no loop. They keep the synchronous load with `os.sleep` and no keys.
- The guard yield interval stays 0.25 s of CPU time (`spec/guard.md` "Yields"). The loader also yields when about 0.1 s have passed since its last yield, before a read, so the loop responds fast.

## Errors after the frame

Decision (user, 2026-11-15): the program will get tabs, so an error after the frame opened must not end the session. Reason: `docs/rationale.md` "Errors keep the session".

- Every fetch error after the frame opened shows as a popup with the error text and an `[OK]` button, over an empty page. This covers: cannot connect, timeout, read error, too many open connections, not an HTML page, too large, no card, HTTP disabled, and a failed redirect. The status line shows the URL and `[error]`.
- A page that broke off is a broken page, and no part of it renders (`docs/rationale.md` "Broken pages are not rendered"). This covers every incomplete load after the frame: a read error in the body, a timeout in the body, and a memory stop by the guard. It holds for a local file too, and for the body of an error status. The popup shows over an empty page. The program drops the lines received so far before it shows the popup.
- The popup text of a broken page has two lines: the error line, then `Reload to try again.` `r` reloads the page (`spec/navigation.md` "Reload").
- The reload line shows for broken pages (body read error, body timeout, memory stop during the render, local read error) and for the retry errors of `fetch.open` (`spec/fetch.md` "Errors"). It does not show for: not an HTML page, compressed response, no internet card, HTTP disabled, too large by the size check before reading (known `Content-Length` or file size), unsupported scheme, redirect errors.
- Two different stops. The size check before reading is a plain error line with no reload line: the same page would fail again. The memory stop during the render is a broken page with the reload line (`spec/guard.md` "Size check before reading").
- After OK, the user can scroll and quit with `q` as usual. The exit code is 0 on a normal quit, and nothing prints on stderr.
- Ctrl+C still exits at once with code 130, also while the popup shows.
- An HTTP error status (404, 500, ...) is not an error here: the short page shows with a popup of two lines, `[HTTP <code>] <phrase>` and the URL (`spec/fetch.md` "HTTP error statuses").
- Not covered: the errors before the frame (argument checks, a missing file, a module that cannot load), an unexpected error, and print mode and the no-screen path. They keep the stderr line, the screen restore and the exit codes of `spec/errors.md`. In print mode and with no screen, a broken page prints no text: only the error line goes to stderr, and the exit code is 1.

## Exit

- The screen is restored on every exit path: normal end, quit during load, controlled error, unexpected error and Ctrl+C.
- Error lines print to stderr after the restore, except the errors that show a popup (see "Errors after the frame").
