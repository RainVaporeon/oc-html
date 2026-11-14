# Project structure

Moved from `SPEC.md` "Project Structure". The code modules (`bin/` and `lib/`) are listed in `SPEC.md` "Components". This file lists the rest of the repository.

```
tests/run.lua           desktop test runner
tests/*_test.lua        unit tests, one file per module
tests/shim/             desktop replacements for OpenOS libraries (internet.lua is a fake internet card)
tests/cases/            small hand-written HTML files with expected output
tests/pages/            generated test pages (large.html: about 1 MB, from tools/genpage.lua)
tests/real/             saved real-world pages
tests/fuzz.lua          random and mutated HTML generator
tests/fuzz-corpus/      seed files that tests/fuzz.lua mutates
tests/fuzz-failures/    fuzz failures (written by the container, not tracked)
tests/docker/Dockerfile test image: alpine:3.20 with the lua5.3 package only
tests/docker/test.ps1   runs the tests in the container with the sandbox flags
docs/intent/mvp.md      confirmed statement of intent
docs/probe/             in-game probe outputs and FACTS.md (measured machine facts)
docs/ingame/            in-game test steps, one file per task
tools/release.ps1       publishes a release and updates releases/latest
tools/installer.lua     installer template (install logic)
tools/mkinstall.lua     builds and checks releases/<version>/html-install.lua (runs in the container)
tools/genpage.lua       deterministic generator of tests/pages/large.html (runs in the container)
tools/memprobe.lua      in-game memory experiments (Task 3c). Not part of a release
tools/probe.lua         in-game machine probe (Task 0). Not part of a release
tools/probe2.lua        in-game probe v2 for the open assumptions (0.0.4a). Not part of a release
tasks/todo.md           roadmap after the MVP
tasks/archive/          finished plans (the MVP plan and task list)
docs/HANDOFF.md         handoff note for a new agent session
docs/rationale.md       reasons and measurements behind the spec rules
docs/testing.md         test coverage (moved from SPEC.md)
docs/netprobe-plan.md   network measurements N1 to N15 and the netprobe plan
docs/code-style.md      code style example module
docs/structure.md       this file
releases/               published release folders and the latest symlink
types/openos.lua        LuaLS type stubs for OpenOS
.luarc.json             LuaLS settings (Lua 5.3, loads types/)
SPEC.md                 the spec index: scope, boundaries, global rules, component table
spec/                   the normative rules, one file per component
```
