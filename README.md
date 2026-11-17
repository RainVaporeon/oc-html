# oc-html

computerception browser for a block game

## features

- web browsing 
- page navigation
- smart page caches
- ssl support
- image viewing

## feature specifications

- smart cache allows a user to backtrack to a previous page without having to re-fetch the entire file.
- link navigation support
- browser tab support
- viewing images (for now PNGs; other extensions will be supported in a future version.)

## install

check the release tab and navigate to the latest version, and pull `html-install.lua` onto your OpenComputers instance and run it.

you can install it to the machine via `html --prefix /` to install on the root directory.

## requirements

the script is tested against a machine with 4MB of storage and 2MB of memory; the script itself takes up ~200kb of space.

- internet card (if you want to view online websites)
- graphics card (if you want to view images)
- 2M disk space (smart page cache saves viewed sites to disk temporarily, and benefits from having more free space)
- 1M memory (loading large websites may take especially much; keep this in mind!)

## notes

this was built for OpenComputers under Gregtech: New Horizons (1.7.10) with Lua 5.3 architecture.

## ai disclosure

this project uses claude code to accelerate development workflow and testing.

### agents

these are issues and ideas found when writing the document, do not modify or commit this file except for checking the checkboxes once the tasks are done.

[ ] the browser happily visits some sites with certificate problems, see: `https://revoked.badssl.com/` and `https://pinning-test.badssl.com/` for example. java-enforced blocks work so some sites are blocked.
[ ] certain setups and components can allow a computer to have significantly more resources than what it is tested on; consider factoring this in when doing page caches as well. the script should assume having up to 50% of the total memory (or 65% of the free memory - whichever lower) and 25% free storage usable.