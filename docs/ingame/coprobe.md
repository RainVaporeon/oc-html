# In-game check: coprobe

Goal: find out whether the planned page loader can run inside a Lua
coroutine. The viewer loop resumes the coroutine. The loader yields in place
of `os.sleep`. The viewer loop owns `event.pull`. Everything goes into one
file, `coprobe.txt`.

Needs: OpenOS on Lua 5.3, a GPU and a keyboard. An Internet Card is optional.
Without it, the network part of Q1 is skipped. The probe needs no installed
`html`.

`<BASE>` is the raw URL of the repository source (the folder that holds
`tools/`).

## 1. Fetch the probe

```
wget -f <BASE>/tools/coprobe.lua /home/coprobe.lua
```

The default `<BASE>` of the project is
`https://raw.githubusercontent.com/RainVaporeon/oc-html/main`.

## 2. Run the probe

```
/home/coprobe.lua
```

Option: `--out <path>` changes the report file (default `/home/coprobe.txt`).

- It takes about one minute.
- At the key step the probe prints `Press keys for 5 seconds`. Press keys
  (any keys, many times) until the probe goes on.
- Ctrl+C stops the probe. It still writes the report.
- A failed question is written as `coprobe.<q>.raise=<text>` and the probe
  goes on.

## 3. Return the output

Copy `/home/coprobe.txt` to `./datacollection/` in the repository (the probe
prints this as its last line). If the probe stops with an error, also paste
the error text exactly as shown.

## What the probe writes

Each line is `coprobe.<key>=<value>`.

| Question | Keys | What it answers |
|---|---|---|
| Q1 | `q1.gpu.*`, `q1.net.*` | A `gpu.set` and an internet card `request`, `finishConnect`, `read` inside a coroutine. `ok=false` with an `error` text (for example "attempt to yield across a C-call boundary") means the call does not work there. |
| Q2 | `q2.*` | `os.sleep(0.2)` and `event.pull(0.1)` inside a coroutine: the time each took, the status seen inside (`running`) and the final status. |
| Q3 | `q3.main_key_down`, `q6.listener_key_down` | Key presses seen by the main loop and by a listener while the coroutine is suspended. Equal counts mean no key is lost. `q3.passes` is the number of resumes. |
| Q4 | `q4.free_*`, `q4.gc_seen` | `computer.freeMemory()` before, after 200 KB of garbage, after the drop, and after 11 main passes. `gc_seen=true` means memory rose again. |
| Q5 | `q5.*` | `ok=false` and a message that contains `coprobe boom` means an error comes back through `coroutine.resume`. |
| Q6 | `q6.listener_ping`, `q6.listener_key_down` | An `event.listen` listener fires while the coroutine is suspended and the main loop is in `event.pull`. `listener_ping=1` means yes. |

The probe makes no other changes. It writes only the report file.
