#!/usr/bin/env python3
r"""Compile a readable keystroke script into the binary KINJ.COM reads.

    python mkkeys.py session.txt > SESSION.KI
    dosdeploy SESSION.KI C:\WORK
    dosexec "C:\TOOLS\KINJ.EXE C:\WORK\SESSION.KI" "SOMEPROG" ^
            "C:\TOOLS\KINJ.COM /D" "C:\TOOLS\KINJ.COM /U"

Script syntax, one directive a line:

    # comment
    DELAY 3          ticks between keys from here on (18.2 ticks a second)
    PAUSE 18         wait a second before the next key
    TEXT hello       type these characters
    KEY Enter        one named key
    KEY Alt-F        Alt- and Ctrl- prefixes are understood
    SNAP             photograph the screen the next time a key is asked for
    END              stop injecting; the real keyboard works again

WHY THE PARSING IS HERE AND NOT IN THE TSR.  KINJ is resident, so every byte
of it is conventional memory somebody else does not get, for as long as it is
loaded.  Key-name tables and number parsing are ~150 lines of assembler that
would sit in memory doing nothing for the entire session.  Same split as
mkwalk.py: the assembler does the part that has to happen on the box, Python
does the part that does not.

TIMING.  A key is delivered when the target ASKS for one, so DELAY is not
about the target keeping up -- it cannot get ahead of us.  It is about giving
a program time to redraw between keystrokes, which matters when the point is
to photograph what it drew.  The default of 2 ticks is about a tenth of a
second.
"""

import sys

# US layout: name -> (scancode, ascii).  AX = scancode<<8 | ascii, which is
# what INT 16h AH=00h returns.
_ROWS = [
    ("1234567890-=",  0x02),
    ("qwertyuiop[]",  0x10),
    ("asdfghjkl;'",   0x1E),
    ("zxcvbnm,./",    0x2C),
]
# Shifted characters sit on the same scancodes.
_SHIFTED = {
    "!@#$%^&*()_+": "1234567890-=",
    "QWERTYUIOP{}": "qwertyuiop[]",
    'ASDFGHJKL:"':  "asdfghjkl;'",
    "ZXCVBNM<>?":   "zxcvbnm,./",
}

CHAR = {}
for text, base in _ROWS:
    for i, ch in enumerate(text):
        CHAR[ch] = (base + i, ord(ch))
for shifted, plain in _SHIFTED.items():
    for sh, pl in zip(shifted, plain):
        CHAR[sh] = (CHAR[pl][0], ord(sh))
CHAR[" "] = (0x39, 0x20)
CHAR["`"] = (0x29, 0x60)
CHAR["~"] = (0x29, 0x7E)
CHAR["\\"] = (0x2B, 0x5C)
CHAR["|"] = (0x2B, 0x7C)

NAMED = {
    "ENTER": (0x1C, 0x0D), "RETURN": (0x1C, 0x0D),
    "ESC": (0x01, 0x1B), "ESCAPE": (0x01, 0x1B),
    "TAB": (0x0F, 0x09),
    "BACKSPACE": (0x0E, 0x08), "BS": (0x0E, 0x08),
    "SPACE": (0x39, 0x20),
    "UP": (0x48, 0), "DOWN": (0x50, 0), "LEFT": (0x4B, 0), "RIGHT": (0x4D, 0),
    "HOME": (0x47, 0), "END": (0x4F, 0),
    "PGUP": (0x49, 0), "PGDN": (0x51, 0),
    "INS": (0x52, 0), "DEL": (0x53, 0),
}
for n in range(1, 11):                      # F1..F10
    NAMED["F%d" % n] = (0x3A + n, 0)
NAMED["F11"] = (0x85, 0)
NAMED["F12"] = (0x86, 0)

# Alt- shifts a letter onto its own scancode with no ASCII at all; Ctrl- gives
# the control code.  Only the letters, which is all anything asks for.
ALT_LETTER = dict(zip("qwertyuiop", range(0x10, 0x1A)))
ALT_LETTER.update(zip("asdfghjkl", range(0x1E, 0x27)))
ALT_LETTER.update(zip("zxcvbnm", range(0x2C, 0x33)))

OP_SNAP, OP_DELAY, OP_PAUSE, OP_END = 0x0000, 0x0001, 0x0002, 0xFFFF


def key_word(name, lineno):
    up = name.upper()
    if up in NAMED:
        sc, asc = NAMED[up]
        return (sc << 8) | asc
    for prefix, kind in (("ALT-", "alt"), ("CTRL-", "ctrl")):
        if up.startswith(prefix):
            rest = up[len(prefix):]
            if len(rest) != 1 or rest.lower() not in ALT_LETTER:
                die(lineno, "%s only understands a single letter" % prefix)
            letter = rest.lower()
            if kind == "alt":
                return ALT_LETTER[letter] << 8
            return (ALT_LETTER[letter] << 8) | (ord(letter) - 96)
    if len(name) == 1 and name in CHAR:
        sc, asc = CHAR[name]
        return (sc << 8) | asc
    die(lineno, "unknown key %r" % name)


def die(lineno, msg):
    raise SystemExit("mkkeys: line %d: %s" % (lineno, msg))


def compile_script(text):
    words = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        verb, _, rest = line.strip().partition(" ")
        verb = verb.upper()
        if verb == "SNAP":
            words.append(OP_SNAP)
        elif verb == "END":
            words.append(OP_END)
        elif verb in ("DELAY", "PAUSE"):
            if not rest.strip().isdigit():
                die(lineno, "%s wants a tick count" % verb)
            words.append(OP_DELAY if verb == "DELAY" else OP_PAUSE)
            words.append(int(rest.strip()) & 0xFFFF)
        elif verb == "KEY":
            words.append(key_word(rest.strip(), lineno))
        elif verb == "TEXT":
            # Everything after "TEXT " verbatim, including runs of spaces --
            # only the leading separator is eaten.
            body = line.strip()[5:] if len(line.strip()) > 4 else ""
            for ch in body:
                if ch not in CHAR:
                    die(lineno, "cannot type %r" % ch)
                sc, asc = CHAR[ch]
                words.append((sc << 8) | asc)
        else:
            die(lineno, "unknown directive %r" % verb)
    if not words or words[-1] != OP_END:
        words.append(OP_END)
    return words


def pack(words):
    out = bytearray(b"KI01")
    out += len(words).to_bytes(2, "little")
    for w in words:
        out += w.to_bytes(2, "little")
    return bytes(out)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    with open(sys.argv[1], "r", encoding="latin-1") as f:
        ws = compile_script(f.read())
    sys.stdout.buffer.write(pack(ws))
    sys.stderr.write("mkkeys: %d word(s)\n" % len(ws))
