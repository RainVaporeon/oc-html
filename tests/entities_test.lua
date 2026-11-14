-- Tests for lib/html/entities.lua (spec/text.md "Entities").

local t = require("test")
local entities = require("html.entities")

local T = {}

local decode = entities.decode

function T.spec_named_entities()
  t.eq(decode("&amp;&lt;&gt;&quot;&apos;"), "&<>\"'")
  t.eq(decode("&nbsp;"), "\xC2\xA0", "nbsp")
  t.eq(decode("&copy;"), "\xC2\xA9", "copy")
  t.eq(decode("&reg;"), "\xC2\xAE", "reg")
  t.eq(decode("&mdash;"), "\xE2\x80\x94", "mdash")
  t.eq(decode("&ndash;"), "\xE2\x80\x93", "ndash")
  t.eq(decode("&hellip;"), "\xE2\x80\xA6", "hellip")
end

function T.extra_named_entities()
  t.eq(decode("&eacute;&Uuml;&szlig;&yuml;"),
    "\xC3\xA9\xC3\x9C\xC3\x9F\xC3\xBF", "Latin-1")
  t.eq(decode("&iexcl;"), "\xC2\xA1", "first Latin-1")
  t.eq(decode("&euro;&trade;&rsquo;&ldquo;"),
    "\xE2\x82\xAC\xE2\x84\xA2\xE2\x80\x99\xE2\x80\x9C", "punctuation")
  t.eq(decode("a&zwj;b&zwnj;c&lrm;d&rlm;e"), "abcde", "invisible marks")
end

function T.unknown_entity_stays()
  t.eq(decode("&bogus; &AMP; & &;"), "&bogus; &AMP; & &;")
  t.eq(decode("a&b"), "a&b")
  t.eq(decode("&#; &#x; &#xG;"), "&#; &#x; &#xG;")
end

function T.no_ampersand_returns_same_string()
  local s = "plain text"
  t.ok(rawequal(decode(s), s))
end

function T.numeric_references()
  t.eq(decode("&#65;&#x41;&#X41;&#0065;"), "AAAA")
  t.eq(decode("&#233;"), "\xC3\xA9")
  t.eq(decode("&#x1F600;"), "\xF0\x9F\x98\x80")
  t.eq(decode("&#x10FFFF;"), "\xF4\x8F\xBF\xBF", "U+10FFFF")
end

function T.numeric_invalid_code_points()
  t.eq(decode("&#0;"), "?", "zero")
  t.eq(decode("&#x0;"), "?", "hex zero")
  t.eq(decode("&#xD800;"), "?", "high surrogate")
  t.eq(decode("&#xDFFF;"), "?", "low surrogate")
  t.eq(decode("&#x110000;"), "?", "above U+10FFFF")
  t.eq(decode("&#99999999999999999999;"), "?", "huge decimal")
  t.eq(decode("&#x00000000041;"), "A", "leading zeros")
end

function T.numeric_follow_cleaning_rules()
  t.eq(decode("a&#1;b&#x5;c&#13;d&#127;e"), "abcde", "controls")
  t.eq(decode("&#9;&#10;"), "\t\n", "tab and newline")
  t.eq(decode("a&#x200B;b&#8204;c&#x200D;d&#xFEFF;e"), "abcde", "zero-width")
  t.eq(decode("a&#173;b&#xAD;c&#8206;d&#x200F;e"), "abcde", "shy, lrm, rlm")
  t.eq(decode("a&shy;b&lrm;c&rlm;d"), "abcd", "named shy, lrm, rlm")
  t.eq(decode("&#x81;"), "", "C1 without a Windows-1252 mapping")
end

function T.numeric_windows_1252()
  t.eq(decode("&#128;"), "\xE2\x82\xAC", "euro")
  t.eq(decode("&#150;&#151;"), "\xE2\x80\x93\xE2\x80\x94", "dashes")
  t.eq(decode("&#x92;"), "\xE2\x80\x99", "right quote")
end

function T.missing_semicolon()
  t.eq(decode("&#65 &#x42x"), "A Bx", "numeric")
  t.eq(decode("&amp"), "&", "legacy at end")
  t.eq(decode("AT&T &lt b"), "AT&T < b", "legacy before space")
  t.eq(decode("&ampx &copyright"), "&ampx &copyright", "followed by alnum")
  t.eq(decode("?a=1&copy=2"), "?a=1&copy=2", "followed by =")
  t.eq(decode("&eacute x"), "&eacute x", "non-legacy needs ;")
end

function T.adjacent_and_repeated()
  t.eq(decode("&&amp;&"), "&&&")
  t.eq(decode("&amp;amp;"), "&amp;", "decoded once")
  t.eq(decode(string.rep("&lt;", 10000)), string.rep("<", 10000))
end

function T.no_style_bytes_for_any_code_point()
  for cp = 0, 0x3FF do
    local out = decode("&#" .. cp .. ";")
    t.ok(not out:find("[\0-\8\11-\31\127]"), "code point " .. cp)
  end
end

return T
