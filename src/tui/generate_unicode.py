"""Generate terminal Unicode tables from a Unicode 16.0.0 UCD directory."""

from pathlib import Path
import sys

UCD = Path(sys.argv[1])


def records(path):
    for line in (UCD / path).read_text(encoding="utf8").splitlines():
        data = line.split("#", 1)[0].strip()
        if not data:
            continue
        bounds, *props = [part.strip() for part in data.split(";")]
        lo, _, hi = bounds.partition("..")
        yield int(lo, 16), int(hi or lo, 16), props


def table(name, records, enum=None):
    merged = []
    for lo, hi, prop in sorted(records):
        if merged and lo == merged[-1][1] + 1 and prop == merged[-1][2]:
            merged[-1] = merged[-1][0], hi, prop
        else:
            merged.append((lo, hi, prop))
    print(f"pub const {name} = [_]Range({enum or 'void'}){{")
    for lo, hi, prop in merged:
        print(f"    .{{ .first = 0x{lo:x}, .last = 0x{hi:x}, .value = {'.' + prop if enum else '{}'} }},")
    print("};")


print("""// Generated from Unicode 16.0.0. See generate_unicode.py and UNICODE-LICENSE.txt.
pub const Grapheme = enum { other, cr, lf, control, extend, zwj, regional_indicator, prepend, spacingmark, l, v, t, lv, lvt };
pub const Indic = enum { none, consonant, linker, extend };
pub fn Range(comptime T: type) type {
    return struct { first: u21, last: u21, value: T };
}
""")
table("grapheme", ((lo, hi, p[0].lower()) for lo, hi, p in records("auxiliary/GraphemeBreakProperty.txt")
                   if p[0] not in {"LV", "LVT"}), "Grapheme")
table("indic", ((lo, hi, p[1].lower()) for lo, hi, p in records("DerivedCoreProperties.txt")
                if p[0] == "InCB"), "Indic")
table("wide", ((lo, hi, "") for lo, hi, p in records("EastAsianWidth.txt") if p[0] in {"W", "F"}))
table("pictographic", ((lo, hi, "") for lo, hi, p in records("emoji/emoji-data.txt")
                      if p[0] == "Extended_Pictographic"))
table("emoji_presentation", ((lo, hi, "") for lo, hi, p in records("emoji/emoji-data.txt")
                           if p[0] == "Emoji_Presentation"))
