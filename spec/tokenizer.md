# Tokenizer

Source: `lib/html/tokenizer.lua`. Index: `SPEC.md`.

## Tokens

- The tokenizer reads its input in 4096-byte chunks and produces tokens one at a time: start, end and text tokens only.
- A start token has a name, the attributes (or none) and a self-closing flag. The flag is set when the tag ends with `/>` (`<br/>`, `<br />`, `<img src=x />`). A `/` inside an unquoted value is part of the value, not the flag (`<a href=/x/>` gives `href` = `/x/`).
- Tag names and attribute names are lowercase (`<DIV>` gives `div`).
- Text and attribute values are cleaned and decoded: `entities.decode(text.clean(s))` (see `spec/text.md`).
- The result does not depend on the chunk edges. A tag, an entity or a UTF-8 sequence that a chunk edge splits gives the same tokens as the whole input.

## Skipped markup

- Comments, doctype, CDATA and processing instructions are skipped. They give no token.
- `<!-->` and `<!--->` are complete (empty) comments.
- `<!` and `<?` start a bogus comment up to the next `>` (`<! x >`, `<?xml y?>`, `<!>`).
- `</` followed by a byte that is not a letter starts a bogus comment up to the next `>` (`</ foo>`, `</3>`).
- `</>` is dropped.
- An unclosed comment, bogus comment or CDATA section ends with the input. Its content gives no token.

## Broken markup

- Never raise an error on bad markup.
- `<` followed by a byte that is not a letter, `!`, `/` or `?` is text (`a < b`, `<3`, `c<` at the end).
- A `<` with no `>` before the end of input becomes text, up to the end of input. Example: `x<a href` at the end of input shows `x<a href`, and `x</a` shows `x</a`.
- A `<` with no `>` within `MAX_TAG` (16384) bytes becomes text in the same way. This bounds the buffer.
- A tag that has a `>` within `MAX_TAG` bytes, but does not end there for another reason (an open quoted value), follows "Broken quoted value" below.

## Attributes

- Attribute values may be quoted (`"` or `'`) or unquoted. A name without a value has the value "".
- Spaces around `=` are allowed (`x = "v"`).
- `x=""` and `x=` give the value "".
- A `>` inside a quoted value does not end the tag (`title="a>b"`).
- For a duplicate name, the first value is kept. Names compare after lowercasing.
- An attribute name with a quote or `<`, or a name that starts with `=`, is broken. The broken attribute is dropped. The other attributes are kept.
- An end tag has no attributes. Text after its name up to `>` is ignored, also a quoted `>` (`</a x=">" y>` ends at the first `>`).

### Broken quoted value

- A quoted value is broken when its closing quote is not within `MAX_TAG` bytes of the `<`, or when it holds a `>` and then `</` (as in `<a href="x>text</a>`).
- A broken quoted value ends the tag at the first `>` in the value. The attribute of the broken value is dropped. The attributes before it are kept.
- The text after that `>` is page text. Example: `<a id=k href="x>y` gives a start tag `a` with `id=k`, then the text `y`.
- When the tag has no `>` at all before the end of input, the rule "A `<` with no `>`" applies, and the tag becomes text.
- When the first `>` of a broken value is not within `MAX_TAG` bytes, the tag ends at the first `>` after its `<`, with no attributes.

## Raw text and RCDATA

- The content of `script` and `style` is skipped up to the matching end tag. A start token and an end token are still produced.
- The content of `title` and `textarea` is text up to the matching end tag. Tags inside it are text. Entities in it are decoded.
- An end tag matches only when its name is followed by a space, a newline, `/` or `>`. `</styles>` and `</style-x>` do not end `style`. Case does not matter (`</SCRIPT >`).
- An unclosed `script` or `style` ends with the input. Its content gives no token.
- Unclosed `title` or `textarea` content is text up to the end of input (`<title>a<b` gives the text `a<b`).

## Implementation rules

- The tokenizer is built on plain `string.find` and `string.byte`. It never runs `gsub` or `gmatch` over large strings (measured costs: `docs/rationale.md` "Design: Pipeline").
- Use plain `find` for long jumps: to the end of a text run (`<`), to `-->` and to `</script`. Use `byte` inside tags, where the parts are short. Use `sub` to cut the text of a token. Use `t[#t+1] = v` for appends.
- The tokenizer never calls `component`. It takes `guard` as its only link to the machine.
