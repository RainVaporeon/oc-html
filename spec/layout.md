# Layout

Source: `lib/html/layout.lua`. Index: `SPEC.md`.

The layout consumes tokens, keeps a small stack of open elements, and appends finished lines. It builds no DOM tree. The line format is in `spec/pipeline.md` "Line format". The layout never calls `component`. It takes `guard` as its only link to the machine.

## Width

- The layout wraps at the layout width. `bin/html.lua` sets it to the output width minus 1 (see `spec/cli.md` "Output width").
- Width uses `unicode.wlen` on the cleaned text, so wide characters fit. A wide character never straddles the width; it moves to the next line.
- Style bytes never count toward the width.

## Element handling

| Elements | Rendering |
|---|---|
| `script style template svg math iframe object noscript` | Dropped with all content |
| `head` | Dropped, but `title` text goes to the status line (see "Title") |
| `h1`-`h6` | Own block with a blank line before and after, heading color |
| `p div section article main header footer nav aside blockquote dt dd` | Block break |
| `br` | Line break |
| `hr` | A line of `─` that fills the layout width |
| `b strong i em u mark` | Emphasis color |
| `a` with `href` | Link color. Not clickable in this version |
| `pre` | Whitespace kept, long lines wrapped |
| `code` | Kept as inline text |
| `img` | `[img: <alt>]`, or `[img]` when there is no alt text or it is empty |
| `li` | Block break with a `- ` prefix |
| `table tr td th ul ol dl form input button select option textarea` | Block breaks only, content as plain text |
| Any other tag | Inline, content kept |

- Unknown tags are treated as inline. Their content is kept.
- A dropped element ends at its own end tag or when a parent closes. A dropped element nested in the same dropped element (`svg` in `svg`) needs its own end tag. A stray end tag of a dropped element is ignored.
- There is no blank line at the start or the end of the output.
- Each `br` gives one line break. Two `br` in a row give one empty line.

## The open-element stack

- Unclosed tags close at the end of the document or when a parent closes.
- A stray end tag with no matching open tag is ignored. It does not close an outer element (`<b>a</i>b</b>`: "b" stays bold).
- Implied ends:
  - The start tag of one of these elements closes an open `p` (the HTML standard list): `address` `article` `aside` `blockquote` `center` `details` `dialog` `dir` `div` `dl` `dd` `dt` `fieldset` `figcaption` `figure` `footer` `form` `header` `hgroup` `hr` `li` `listing` `main` `menu` `nav` `ol` `p` `plaintext` `pre` `search` `section` `summary` `table` `ul` `xmp` `h1` `h2` `h3` `h4` `h5` `h6`.
  - No other start tag closes a `p`. In particular `tr`, `td`, `th`, `input`, `button`, `select`, `textarea`, `option`, `a`, `span` and `br` do not.
  - `li` closes an open `li`. The search stops at `ul`, `ol` or `menu`.
  - `dt` and `dd` close an open `dt` or `dd`. The search stops at `dl`.
  - `tr` closes an open `tr`, `td` or `th`. The search stops at `table`.
  - `td` and `th` close an open `td` or `th`. The search stops at `tr` or `table`.
  - `option` closes an open `option`. The search stops at `select`.
  - `body` closes `head`. An unclosed `title` in `head` also ends there.
- Inline styles continue after a misnested inline end tag. When an end tag closes an outer inline element, the inner style elements that are still open continue after it, as in browsers. They end at their own end tag or when a parent closes. Example: `<i><b>a</i>b</b>c` shows "a" and "b" in the emphasis style and "c" in the normal style.
- When a block or heading element closes, the inline elements still open inside it close with it (`<p>a <b>b</p>c`: "c" is normal). A stray `<b>` then cannot make the rest of the page bold.
- Styles nest. The innermost style wins. When it closes, the outer style returns (`<a href=x>a<b>b</b>c</a>`: "a" link, "b" emphasis, "c" link).
- Depth bound: the stack holds at most 256 open elements (`MAX_DEPTH`). A start tag past the bound does not go on the stack. Its style is lost: its text shows in the style of the innermost element on the stack. A dropped element past the bound still hides its content. Deep nesting inside a dropped element is still hidden.

## White space

- Outside `pre`, white space collapses to one space. White space is space, tab and newline. Other characters, also U+00A0 from `&nbsp;`, are not white space: they do not collapse, and a line does not wrap at them.
- A block has no leading or trailing space.
- A space at a style change is kept once (`a <b> b </b> c` gives "a b c" with one space at each change).
- A word can span several text tokens and inline tags (`hel<b>lo</b>` is one word).

## Wrapping

- Lines wrap at word boundaries to the layout width.
- A word wider than the width is split at the width.
- A word with a style change inside it wraps as one word.
- A style continues on the next line after a wrap, also inside a split word.

## Lists

- Each `li` starts a block with the prefix `- `.
- Nested lists have no indent.
- A wrapped `li` line has no prefix. Only the first line of an item has `- `.

## Images

- The alt text of `img` collapses its white space and trims it, like other text.
- `[img: <alt>]` wraps like text.

## Preformatted text

- Inside `pre`, white space is kept. Long lines wrap hard at the layout width.
- `pre` drops one newline directly after the start tag, as in the HTML standard. Further newlines are kept.
- Tabs: the game draws a tab as a 2-cell glyph (measured: `wlen("a\tb")` = 4). Inside `pre`, the layout expands each tab to spaces up to the next 8-column stop before it measures the width. A tab never expands past the width: the expansion stops at the line end. Outside `pre`, the whitespace collapse removes tabs. No tab reaches an output line.
- Emphasis and links inside `pre` keep the white space.

## Title

- The document title is the text of the first `title` element. A `title` inside `svg` or another dropped element other than `head` is not the document title.
- The title text collapses its white space to one space and is trimmed.
- An empty title (after trimming) counts as no title.
- The title keeps at most 256 bytes. A longer title is cut at a UTF-8 character boundary.
- The layout reads at most 1024 bytes of raw title text. Leading white space does not count toward this limit, so a title after much white space is kept.
