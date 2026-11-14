# Text cleaning and entities

Source: `lib/html/text.lua`, `lib/html/entities.lua`. Index: `SPEC.md`.

## Text cleaning

Text is treated as UTF-8 and is cleaned before any `unicode.*` call.

`unicode.*` never throws on bad bytes. It turns them into U+FFFD and can count a wrong width. `utf8.len` accepts encoded surrogates. So the program cleans all text before any `unicode.*` call:

- Invalid sequences, truncated sequences, overlong forms and encoded surrogates (U+D800 to U+DFFF) become `?`.
- One `?` replaces each maximal invalid subpart (Unicode recommended practice). So an encoded surrogate gives 3 `?` (the game shows one U+FFFD).
- DEL 0x7F and the C1 controls U+0080 to U+009F are removed.
- The removed zero-width and invisible characters are U+00AD, U+200B, U+200C, U+200D, U+200E, U+200F and U+FEFF. (`unicode.wlen` counts U+200B as width 2.)
- The variation selectors U+FE00 to U+FE0F are removed. (U+FE0F is wide in the game: `wlen` 2, measured.)
- Control bytes below 0x20 are removed, except tab and newline. `\r` is removed.
- Decoded entities pass through the same rules.
- The tokenizer calls `entities.decode(text.clean(s))`. A partial UTF-8 sequence or entity at a chunk end is held back with `text.split_tail` and joined to the next chunk.
- Cleaning removes all control bytes, so text never contains the style bytes 0x01 to 0x05 (see `spec/pipeline.md` "Line format").

## Entities

- The common named entities (`&amp; &lt; &gt; &quot; &apos; &nbsp; &copy; &reg; &mdash; &ndash; &hellip;` and similar) and numeric `&#N;` and `&#xN;` decode. An unknown entity stays as written.
- Named entities: the list above, all Latin-1 names and a set of common typographic names. Names are case-sensitive.
- `&nbsp;` decodes to U+00A0. For its effect on white space, see `spec/layout.md` "White space".
- Numeric references 128 to 159 use the Windows-1252 table.
- A numeric reference without ";" decodes. Only amp, lt, gt, quot, nbsp, copy and reg decode without ";", and only when the next byte is not a letter, digit or "=".
- A reference to 0, a surrogate or a code point above U+10FFFF gives "?". A reference to a control or invisible character gives "".
