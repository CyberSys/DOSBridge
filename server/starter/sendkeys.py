#!/usr/bin/env python3
r"""Send keystrokes to KNET.COM on the DOS box, live, over UDP.

    python sendkeys.py 192.168.1.255              interactive: type, it goes
    python sendkeys.py 192.168.1.255 --show       ...print keys, send nothing
    python sendkeys.py 192.168.1.255 --text "DIR" send a string once
    python sendkeys.py 192.168.1.255 --test       a known burst, for KNET /T

USE THE BROADCAST ADDRESS. The DOS box cannot answer ARP while KNET holds the
IP handle, so Windows stops delivering unicast to it -- measured as 0 frames
against 23 for broadcast in the same run. See knet.md.

WIRE FORMAT
-----------
One UDP datagram, port 8071 by default:

    'K' 'N' '0' '1'   magic
    <count>           little-endian word, how many keys follow
    <key> ...         little-endian words, AH=scancode AL=ascii

A key word is exactly what INT 16h AH=00h returns, so the DOS side does no
translation at all -- it copies the word into its ring and hands it over.

READING THE KEYBOARD: EVENTS, NOT CHARACTERS
--------------------------------------------
This used to use msvcrt.getch(), and Alt-combinations did not work at all --
the console never hands them to getch() as characters, so Alt-F was silently
unsendable, which made KNET useless for anything with a menu.

ReadConsoleInput gives the whole key event instead: virtual key, scan code,
character and modifier state. Two things fall out of that:

  * Alt and Ctrl combinations arrive, because the modifier state is explicit
    rather than folded into a character that does not exist.
  * Windows' wVirtualScanCode IS the PC set-1 scan code, the same number DOS
    reports through INT 16h. So the word can be built from what the key
    actually is rather than translated through a table of guesses. Arrows,
    function keys and Alt-letters all come out right without special cases.

The mkkeys tables are still used for --text, where there is no keyboard to
read and a character is all we have.
"""

import argparse
import socket
import struct
import sys

PORT = 8071
MAGIC = b"KN01"

try:
    from mkkeys import CHAR, NAMED
except ImportError:
    sys.exit("sendkeys: mkkeys.py must be beside this script")


def pack(keys):
    return MAGIC + struct.pack("<H", len(keys)) + b"".join(
        struct.pack("<H", k) for k in keys)


def key_of(ch):
    """A character -> an INT 16h word, for --text."""
    if ch in CHAR:
        sc, asc = CHAR[ch]
        return (sc << 8) | asc
    return None


# ---------------------------------------------------------------- console ---

def _console():
    """Raw console input via ReadConsoleInput. Returns a generator of
    (scancode, ascii, alt, ctrl) or None if this is not a real console."""
    import ctypes
    from ctypes import wintypes

    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    STD_INPUT = -10
    h = k32.GetStdHandle(STD_INPUT)
    if h == 0 or h == -1:
        return None

    class CHAR_U(ctypes.Union):
        _fields_ = [("UnicodeChar", wintypes.WCHAR),
                    ("AsciiChar", ctypes.c_char)]

    class KEY_EVENT(ctypes.Structure):
        _fields_ = [("bKeyDown", wintypes.BOOL),
                    ("wRepeatCount", wintypes.WORD),
                    ("wVirtualKeyCode", wintypes.WORD),
                    ("wVirtualScanCode", wintypes.WORD),
                    ("uChar", CHAR_U),
                    ("dwControlKeyState", wintypes.DWORD)]

    class EVENT_U(ctypes.Union):
        # Only KeyEvent is read, but the union must be the size of the
        # largest member or ReadConsoleInput writes past the buffer.
        _fields_ = [("KeyEvent", KEY_EVENT),
                    ("_pad", ctypes.c_byte * 16)]

    class INPUT_RECORD(ctypes.Structure):
        _fields_ = [("EventType", wintypes.WORD), ("Event", EVENT_U)]

    KEY_EVENT_TYPE = 0x0001
    ALT = 0x0001 | 0x0002          # RIGHT_ALT_PRESSED | LEFT_ALT_PRESSED
    CTRL = 0x0004 | 0x0008         # RIGHT_CTRL_PRESSED | LEFT_CTRL_PRESSED

    # Raw mode: without this the console eats Ctrl-C and buffers whole lines,
    # neither of which is any use when the keystrokes are meant for another
    # machine. Restored on the way out.
    old = wintypes.DWORD()
    if not k32.GetConsoleMode(h, ctypes.byref(old)):
        return None
    k32.SetConsoleMode(h, 0)

    def gen():
        try:
            rec = INPUT_RECORD()
            n = wintypes.DWORD()
            while True:
                if not k32.ReadConsoleInputW(h, ctypes.byref(rec), 1,
                                             ctypes.byref(n)) or n.value == 0:
                    return
                if rec.EventType != KEY_EVENT_TYPE:
                    continue
                ke = rec.Event.KeyEvent
                if not ke.bKeyDown:
                    continue
                state = ke.dwControlKeyState
                ch = ke.uChar.UnicodeChar
                code = ord(ch) if ch else 0
                if code > 0xFF:
                    continue                     # not something DOS can take
                yield (ke.wVirtualScanCode, code,
                       bool(state & ALT), bool(state & CTRL))
        finally:
            k32.SetConsoleMode(h, old)

    return gen()


def word_of(scan, code, alt, ctrl):
    """Build the INT 16h word DOS would report for this key.

    Windows' scan code is already the set-1 code DOS uses, so the only real
    decision is what goes in the low byte.
    """
    if alt:
        # DOS reports Alt-<key> as the scan code with NO character at all.
        # Windows agrees and gives code 0, but say so explicitly rather than
        # relying on it.
        return (scan << 8) & 0xFF00
    if ctrl and code == 0:
        return (scan << 8) & 0xFF00
    return ((scan << 8) | (code & 0xFF)) & 0xFFFF


def describe(scan, code, alt, ctrl):
    bits = []
    if alt:
        bits.append("Alt")
    if ctrl:
        bits.append("Ctrl")
    ch = chr(code) if 32 <= code < 127 else ""
    return "scan %02X  ascii %02X %-3s %s" % (
        scan, code, repr(ch)[1:-1] if ch else "", "+".join(bits))


def interactive(sock, addr, show=False):
    gen = _console()
    if gen is None:
        sys.exit("sendkeys: interactive mode needs a real Windows console")

    print("Typing straight through to the DOS box.  Ctrl-] to stop.")
    if show:
        print("--show: printing keys, sending NOTHING.")
    print("Alt- and Ctrl- combinations are sent; watch with `doscap live`.")
    print()
    for scan, code, alt, ctrl in gen:
        if code == 0x1D and not alt:                # Ctrl-]
            print("\nsendkeys: stopped")
            return 0
        word = word_of(scan, code, alt, ctrl)
        if word == 0:
            continue                               # a bare modifier key
        if show:
            print("  %s   -> %04X" % (describe(scan, code, alt, ctrl), word))
        else:
            sock.sendto(pack([word]), addr)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("host", help="BROADCAST address, e.g. 192.168.1.255")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--test", action="store_true",
                    help="send a known burst and exit, for KNET /T")
    ap.add_argument("--text", help="send this text once, then exit")
    ap.add_argument("--show", action="store_true",
                    help="print what each key would send, send nothing")
    a = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # Broadcast is the one address that needs no ARP, and the DOS box does not
    # answer ARP while KNET holds the IP handle.
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    addr = (a.host, a.port)

    if a.test:
        keys = [(CHAR["A"][0] << 8) | CHAR["A"][1],
                (CHAR["B"][0] << 8) | CHAR["B"][1],
                (CHAR["C"][0] << 8) | CHAR["C"][1],
                (NAMED["ENTER"][0] << 8) | NAMED["ENTER"][1]]
        print("sendkeys: %s:%d  <- %s x8"
              % (a.host, a.port, " ".join("%04X" % k for k in keys)))
        import time
        for _ in range(8):
            sock.sendto(pack(keys), addr)
            time.sleep(0.5)
        return 0

    if a.text:
        keys = []
        for c in a.text:
            w = key_of(c)
            if w is None:
                sys.exit("sendkeys: cannot type %r" % c)
            keys.append(w)
        for i in range(0, len(keys), 64):      # 128 words is KNET's ceiling
            sock.sendto(pack(keys[i:i + 64]), addr)
        print("sendkeys: sent %d key(s)" % len(keys))
        return 0

    return interactive(sock, addr, show=a.show)


if __name__ == "__main__":
    sys.exit(main())
