-- Tests for lib/html/entities.lua (spec/text.md "Entities").

local t = require("test")
local entities = require("html.entities")

local T = {}

local decode = entities.decode

local DECODE = {
  -- The common named entities decode.
  { "basic five", "&amp;&lt;&gt;&quot;&apos;", "&<>\"'" },
  { "nbsp", "&nbsp;", "\xC2\xA0" },
  { "copy", "&copy;", "\xC2\xA9" },
  { "reg", "&reg;", "\xC2\xAE" },
  { "mdash", "&mdash;", "\xE2\x80\x94" },
  { "ndash", "&ndash;", "\xE2\x80\x93" },
  { "hellip", "&hellip;", "\xE2\x80\xA6" },
  -- All Latin-1 names and a set of common typographic names.
  { "Latin-1", "&eacute;&Uuml;&szlig;&yuml;",
    "\xC3\xA9\xC3\x9C\xC3\x9F\xC3\xBF" },
  { "first Latin-1", "&iexcl;", "\xC2\xA1" },
  { "typographic", "&euro;&trade;&rsquo;&ldquo;",
    "\xE2\x82\xAC\xE2\x84\xA2\xE2\x80\x99\xE2\x80\x9C" },
  -- An unknown entity stays as written. Names are case-sensitive.
  { "unknown and wrong case", "&bogus; &AMP; & &;", "&bogus; &AMP; & &;" },
  { "bare &", "a&b", "a&b" },
  { "empty numeric", "&#; &#x; &#xG;", "&#; &#x; &#xG;" },
  { "no ampersand", "plain text", "plain text" },
  -- Numeric references.
  { "decimal and hex", "&#65;&#x41;&#X41;&#0065;", "AAAA" },
  { "decimal two bytes", "&#233;", "\xC3\xA9" },
  { "hex four bytes", "&#x1F600;", "\xF0\x9F\x98\x80" },
  { "U+10FFFF", "&#x10FFFF;", "\xF4\x8F\xBF\xBF" },
  { "leading zeros", "&#x00000000041;", "A" },
  -- 0, a surrogate or a code point above U+10FFFF gives "?".
  { "zero", "&#0;", "?" },
  { "hex zero", "&#x0;", "?" },
  { "high surrogate", "&#xD800;", "?" },
  { "low surrogate", "&#xDFFF;", "?" },
  { "above U+10FFFF", "&#x110000;", "?" },
  { "huge decimal", "&#99999999999999999999;", "?" },
  -- A control or invisible character gives "".
  { "controls", "a&#1;b&#x5;c&#13;d&#127;e", "abcde" },
  { "tab and newline kept", "&#9;&#10;", "\t\n" },
  { "zero-width", "a&#x200B;b&#8204;c&#x200D;d&#xFEFF;e", "abcde" },
  { "shy, lrm, rlm", "a&#173;b&#xAD;c&#8206;d&#x200F;e", "abcde" },
  { "named shy, lrm, rlm", "a&shy;b&lrm;c&rlm;d", "abcd" },
  { "named zwj, zwnj, lrm, rlm", "a&zwj;b&zwnj;c&lrm;d&rlm;e", "abcde" },
  { "C1 without a Windows-1252 mapping", "&#x81;", "" },
  -- 128 to 159 use the Windows-1252 table.
  { "euro", "&#128;", "\xE2\x82\xAC" },
  { "dashes", "&#150;&#151;", "\xE2\x80\x93\xE2\x80\x94" },
  { "right quote", "&#x92;", "\xE2\x80\x99" },
  -- Without ";".
  { "numeric without ;", "&#65 &#x42x", "A Bx" },
  { "legacy at end", "&amp", "&" },
  { "legacy before space", "AT&T &lt b", "AT&T < b" },
  { "legacy before alnum", "&ampx &copyright", "&ampx &copyright" },
  { "legacy before =", "?a=1&copy=2", "?a=1&copy=2" },
  { "non-legacy needs ;", "&eacute x", "&eacute x" },
  -- Each reference decodes once.
  { "adjacent", "&&amp;&", "&&&" },
  { "decoded once", "&amp;amp;", "&amp;" },
  { "repeated", string.rep("&lt;", 10000), string.rep("<", 10000) },
}

t.cases(T, "decode", DECODE, function(input)
  return decode(input)
end)

-- spec/text.md: decoded entities pass through the cleaning rules, so text
-- never holds a style byte or another control byte.
function T.no_style_bytes_for_any_code_point()
  for cp = 0, 0x3FF do
    local out = decode("&#" .. cp .. ";")
    t.ok(not out:find("[\0-\8\11-\31\127]"), "code point " .. cp)
  end
end

return T
