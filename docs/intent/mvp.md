# oc-html MVP: statement of intent

Confirmed with the project owner on 2026-11-14.

- **Outcome:** An `html ./file.html` command that renders any local HTML file as readable text on an OpenComputers screen. That includes small test files, saved real-world pages and randomly generated or broken markup.
- **User:** The project owner first, then other GT:NH (Minecraft 1.7.10) players. No public script does this today.
- **Why now:** Nobody has built it, and it was out of reach when planned alone. A working MVP proves "unrealistic" wrong and becomes the base for remote browsing.
- **Success:**
  - No crash, out-of-memory error or "too long without yielding" error on any input.
  - `<script>`, `<style>` and other content that cannot be shown is dropped.
  - Headings, paragraphs, line breaks and emphasis are shown with sensible structure.
  - Links are visible but do not need to work yet.
  - Pages longer than the screen can be scrolled.
- **Constraint:** Plain Lua 5.3 on OpenComputers, with no external processing. Designed for a tier 3 GPU and screen (160x50) with 2x tier 3.5 memory. It should still work on tier 2. A data card is optional.
- **Out of scope for the MVP:** Remote fetching and following links, tabs, shell tab-out, downloads, saved sessions, CSS and JS, images, and correct rendering of tables, lists, forms, `<input>` and `<button>`. These elements must not break anything, but they can render as plain text.

## Roadmap after the MVP

1. Remote pages and link navigation.
2. Tabs, shell tab-out, downloads and saved sessions.
3. Correct rendering of tables, lists and forms.
4. Images, which will probably need heavy compression.
