# URL arguments

Source: `lib/html/fetch.lua` (`M.parse_url`, `M.looks_like_host`), dispatch in `bin/html.lua`. Index: `SPEC.md`. Decisions D4 and D5: `docs/rationale.md` "Remote fetching: decisions".

## Forms

```
html [options] http://host[:port][/path][?query][#fragment]
html [options] https://host[:port][/path][?query][#fragment]
html [options] host[:port][/path][?query]     http is assumed (see "Arguments without a scheme")
```

- All options of a local file work the same: `--print`, `--width`, `--no-rescale`.

## URL parsing

- An argument is a URL when it starts with `http://` or `https://`. The scheme is not case-sensitive.
- An argument that starts with another scheme (`<letter>[letters, digits, + . -]://`, for example `ftp://` or `file://`) stops with `html: unsupported URL scheme: <scheme>`, exit code 2. The scheme in the message is lowercase.
- Any other argument goes through "Arguments without a scheme".
- The host must not be empty. A URL with a space, a control byte or a byte above 0x7E stops with `html: invalid URL: <url>`, exit code 2. The program does not percent-encode. The user types an encoded URL.
- The fragment (`#...`) is removed before the request. It is not sent to the server.
- The URL is at most 2048 bytes. A longer URL stops with `html: invalid URL: too long`.
- The default port is 80 for `http` and 443 for `https`.
- The path is `/` when the URL has none. A query without a path is kept as the path (`http://example.com?q` gives the path `?q`).
- The URL text keeps the case and form that the user typed (without the fragment). Only the scheme is compared without case.
- Port and path checks beyond these rules are left to the card. It rejects a bad address with its own message (see `spec/fetch.md` "Errors").
- The parser is a small pure function in `lib/html/fetch.lua` (`M.parse_url(s)`). It returns a table (`scheme`, `host`, `port`, `path`, `url` without fragment) or nil and a reason. Roadmap item 2 extends it into a full resolver.

## Arguments without a scheme

Decision D4. An argument without `://` is checked in this order:

1. Local file. The program expands `~` and calls `shell.resolve`, as before. When the resolved path exists (a file or a directory), the argument is local. The existing rules apply (`html: not a file: <file>` for a directory).
2. Host. When no such path exists and the argument "looks like a host" (below), the URL is `http://<arg>`. The URL parsing rules then apply to it.
3. Otherwise the argument stays local, and the program stops with `html: file not found: <arg>`, as before.

The argument looks like a host when all of these are true:
- It does not start with `/`, `.` or `~`.
- It has no space, no control byte and no byte above 0x7E.
- Its host part is the text up to the first `/`, `?` or `#`, or the whole argument when it has none. So a `/` before the first dot puts the dot outside the host part (`dir/x.com` is not a host).
- The host part is `name` or `name:port`. `port` is 1 to 5 digits with a value from 1 to 65535.
- `name` is `localhost` (not case-sensitive), or two or more labels joined by `.`. Each label is 1 to 63 bytes of ASCII letters, digits and `-`. A label does not start or end with `-`. A dotted IPv4 address matches this rule.
- The last label of `name` is not a local file extension: `html`, `htm`, `xhtml`, `txt` or `lua` (not case-sensitive). So a missing `page.html` gives "file not found", not a network request. (Decision D5.)

- The check is a pure function `fetch.looks_like_host(arg)`. The file check stays in `bin/html.lua` (`deps.exists`).
- Each fetch error for a guessed URL ends with ` (no local file named <arg>)`. This makes a mistyped file name clear.
- A guessed `localhost` URL usually fails with the card's blocked-address message (N12). That is the expected result.
- When `deps.exists` is not given (tests only), an argument without a scheme is always local. (Implementation note 12.)
- The expected results for a list of arguments: `docs/testing.md` "Remote fetching".
