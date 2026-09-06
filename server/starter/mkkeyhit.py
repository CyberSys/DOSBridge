"""Emit build/KEYHIT.COM -- a 22-byte ScrollLock test for the agent loop.

Why a lock key and not a keypress
---------------------------------
The obvious design is to read the BIOS keyboard buffer and look for Q. It does
not work, and it fails silently, which is worse. mTCP's tools watch the keyboard
so you can abort a transfer with ESC or Ctrl-Break, and in doing so they CONSUME
whatever is waiting. The agent spends almost all of its time inside HTGET
long-polling for a job, so a Q pressed at a random moment is eaten by HTGET
before the loop ever gets to look. Measured on hardware 2026-09-01:

    STUFFQ then KEYHIT              -> rc 1   (the key was there)
    STUFFQ then HTGET then KEYHIT   -> rc 0   (HTGET ate it)

ScrollLock is immune to that. It is not a queued keystroke at all -- it is a bit
in the BIOS keyboard flags byte at 0040:0017, set by the keyboard ISR and left
alone by everything else. It also has a visible LED, so the machine shows its
own armed/disarmed state without anything having to be on screen.

Why this is not a Pascal program
--------------------------------
AI.BAT runs this once per poll, roughly every eight seconds, forever. An FPC
binary is 25 KB minimum and would be re-loaded from disk every time -- and
`uses About` would repaint the attribution banner every eight seconds, making
the console useless. Hand-assembled, it is small enough that the load is free.

There is no assembler on the Windows side, and keeping a .ASM *and* a byte table
by hand would be two sources of truth that drift. So the listing below is the
source, the bytes beside it are the output, and this file is both. MNASMFIX.COM
on the DOS box can reassemble the same listing if that is ever wanted (see
CLAUDE.md, "Assembling on the DOS box itself").

Behaviour
---------
Exit 1 if ScrollLock is on, else 0. Prints nothing, so it is invisible in the
loop, and touches no keyboard state -- the LED keeps telling the truth.
"""

import os

# org 100h
CODE = [
    (0x00, "B8 40 00",    "mov  ax, 40h      ; the BIOS data area"),
    (0x03, "8E D8",       "mov  ds, ax"),
    (0x05, "A0 17 00",    "mov  al, [0017h]  ; keyboard flags byte"),
    (0x08, "A8 10",       "test al, 10h      ; bit 4 = ScrollLock active"),
    (0x0A, "74 05",       "jz   off          ; -> +0x11 = 0x11"),
    (0x0C, "B8 01 4C",    "mov  ax, 4C01h    ; exit 1 -- stop the agent"),
    (0x0F, "CD 21",       "int  21h"),
    # off:
    (0x11, "B8 00 4C",    "mov  ax, 4C00h    ; exit 0 -- carry on polling"),
    (0x14, "CD 21",       "int  21h"),
]

blob = bytearray()
for off, hexs, _asm in CODE:
    assert off == len(blob), "listing offset %02X != %02X" % (off, len(blob))
    blob += bytes(int(b, 16) for b in hexs.split())

# A wrong jump displacement lands mid-instruction rather than failing loudly,
# so check it instead of trusting it.
assert blob[0x0B] == 0x11 - 0x0C, "jz displacement"

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "build")
os.makedirs(out, exist_ok=True)
path = os.path.join(out, "KEYHIT.COM")
with open(path, "wb") as fh:
    fh.write(blob)
print("wrote %s (%d bytes)" % (path, len(blob)))
