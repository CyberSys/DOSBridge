# CLAUDE.md

Project context for Claude Code. Read this before touching anything here.

## What this is

A bridge that lets you build DOS software on this Windows 11 machine and run it
on a real 8086-class PC over WiFi. The DOS box is reachable as a test runner:
you run a command, it executes on the DOS machine, you get stdout and an exit
code back. Treat it exactly like a compiler or test suite.

Nothing in the bridge or in `starter/` is tied to one CPU. Everything is built
for the plain 8086 so it runs on any DOS box; where a faster part can do
better, the fast path is selected at run time via `Has186` in `starter/cpu.pas`.
The specifics below describe *this* machine, not a requirement.

Hardware: NEC V30, MS-DOS 6.22, PicoMEM 1.14 card providing WiFi. About 514 KB
free heap.

| | |
|---|---|
| Windows box | runs `dosd.py` on ports 8080/8081/8082, plus UDP 8069 |
| DOS box | polls for jobs at a static address; see below |

**Every IP address and MAC in this file is an illustrative placeholder.** They
are written as `192.168.1.x` and `AA:BB:CC:...` so a transcript reads sensibly,
not because any of them mean anything. Nothing in the bridge has an address
baked into it: the Windows side is auto-detected, the DOS side is written into
`C:\AI\NET.CFG` when the client kit is built, and both are reported by
`dosctl status` and by the box's own boot banner. If you are copying a command
out of this file, substitute your own.

## How this box is actually set up

Verified by reading the machine, not from these notes. **The `dos/` directory in
this repo does not match it** — deploying `dos/AUTOEXEC.BAT` as `README.md` step
4 describes would break networking.

| | on the box |
|---|---|
| packet driver | `C:\drivers\pm2000.com 0x60` (PicoMEM native, not NE2000) |
| addressing | `DHCP` |
| mTCP | `C:\NETWORK\MTCP`, config `c:\network\mtcp\mtcp.cfg` |
| boot chain | `CONFIG.SYS` → `AUTOEXEC.BAT` → `cd AI` → `C:\AI\AI.BAT` |
| agent loop | `C:\AI\AI.BAT` — the job loop and crash guard live here |
| work dirs | `C:\AGENT` (bridge state), `C:\TOOLS` (permanent, on PATH), `C:\WORK` (per-job scratch) |

### Why three working directories

Renamed on 2026-08-30. `C:\A` and `C:\T` are gone; do not recreate them.

| | |
|---|---|
| `C:\AI` | the agent loop itself — `AI.BAT`, `REBOOT.COM`, `COLDBOOT.COM` |
| `C:\AGENT` | bridge state — `JOB.BAT`, `EXIT0.COM`, `PEND.BAT`, `PENDID.TXT`, `TRYING.FLG`, `DRVOUT.TXT` |
| `C:\TOOLS` | the permanent tools, and the reason they resolve by bare name |
| `C:\WORK` | per-job scratch — pushed programs, `OUT.TXT`, `RES.TXT` |

The split that matters is `TOOLS` from `WORK`. The old `C:\T` held both the
disposable scratch *and* the entire toolset, so `DEL C:\T\*.*` — the obvious way
to clear scratch — would have taken `HWINFO`, `DEVS`, `SCRAPE` and the rest with
it. `C:\WORK` is now safe to wipe at any time and `C:\TOOLS` is never touched by
a job.

`C:\AGENT` is separate from `C:\WORK` because some of it must **survive a
reboot**: `PEND.BAT`, `PENDID.TXT` and `TRYING.FLG` are written by one boot and
read by the next, and they are the only way the machine can report *why* it
hung. Never write there yourself — a stray `PEND.BAT` or `TRYING.FLG` makes the
next boot think a driver test is in flight.

Paths live in `dosd.py` (generated batches), `dosctl.py` (the `deploy` default),
`C:\AI\AI.BAT` on the box, and the `PATH` line in `C:\AUTOEXEC.BAT`. Change one
without the others and jobs half-work. No `.pas` source hardcodes them.

**The network is STATIC, and must stay that way.** As of 2026-08-30 the box no
longer runs `DHCP` at boot; `C:\NETWORK\MTCP\MTCP.CFG` carries `IPADDR
192.168.1.20` with no lease. Before that it took a 4-hour DHCP lease, and when
the lease expired every mTCP tool refused to run — the box went silent and
needed hands on the keyboard.

The reason it could not recover by itself is worth remembering: `AI.BAT`'s
`:OFFLINE` branch retries `HTGET` every 5 seconds forever but **never re-runs
`DHCP`**, so once the lease lapsed it retried the one thing that could not
work. `DHCP.EXE` is one-shot — it stamps the address plus `TIMESTAMP` and
`LEASE_TIME` into `MTCP.CFG` and exits; nothing renews it.

So: never re-enable the `DHCP` line in `AUTOEXEC.BAT`, and never hand-write
`TIMESTAMP` or `LEASE_TIME` into `MTCP.CFG`. Those two directives are exactly
what the tools test to decide a lease has expired. Backups on the box are
`C:\AUTOEXEC.SAV` and `C:\NETWORK\MTCP\MTCP.BAK`; the live files are mirrored in
`dos/live/`, with the pre-static version kept in `dos/archive/`.
**`dos/live/AUTOEXEC.BAT` had drifted and was not a mirror at all** --
corrected 2026-08-31 by pulling the real one. The better, never-deployed
version is now `dos/AUTOEXEC.proposed.bat`; it is what would put
`C:\TOOLS` on the box's PATH.

Symptom to recognise: the box stops polling and never comes back on its own,
while `dosd` is plainly still listening on 8080/8081/8082. Check with `netstat`
before assuming the daemon died — the failure looks identical from the CLI.

**The clock was two years slow, and is now right.** Every file the box created
was stamped 2024 while the world was in 2026 -- month, day, hour and minute all
correct, only the year wrong. Fixed on 2026-08-31 with the mTCP client already
on the machine:

```
dosexec "SET TZ=EST5EDT" "SNTP -set pool.ntp.org"
```

It **survived a reboot**, so the CMOS battery is fine and the year had simply
never been set. Two things worth keeping:

* `SNTP` and `HTGET` both refuse to touch timestamps unless `TZ` is set, and
  `AUTOEXEC.BAT` does not set it -- so the `SET TZ=` above is needed on any job
  that cares, until someone adds it at the keyboard.
* Never run bare `DATE` or `TIME` over the bridge to check the clock. With no
  argument they prompt for input and block forever, which is indistinguishable
  from a hang and needs hands on the machine. `SNTP` without `-set` reports
  both times and changes nothing, which is the safe way to ask.

**The video card boots to mono sometimes.** Observed both ways in one session:
display combination code 7 (VGA mono, text mode 7) on one boot and code 8 (VGA
colour, text mode 3) on the next, with no configuration change. Anything that
touches the screen must decide at *run time* — probe `INT 10h AH=1Ah` (AL=1Ah
means the code in BL is valid; 1, 5, 7 and 0Bh are mono) rather than baking in a
palette. `starter/fractal.pas` does this and takes a `MONO`/`COLOUR` argument to
override the probe, which is how to test the path the card didn't boot into.

Note a colour ramp is *not* automatically safe on mono: the monitor sums R+G+B,
so two different colours can land on the same grey. Mono needs its own evenly
spaced ramp.

`C:\MTCP` exists but is empty; the real tools are under `C:\NETWORK\MTCP`.
`CONFIG.SYS` has one active line, `device=c:\bp\bin\ch375R9.sys`. The box also
carries unrelated software (`WINDOWS`, `BP`, `GAMES`, `NASM`) — don't disturb it.

## Prerequisite for every session

`dosd.py` must already be running in its own window. If commands hang or report
"cannot reach dosd", say so — do not try to start it yourself in a way that
blocks, and do not work around it by skipping hardware tests.

**dosd writes `dosd.log` beside `dosd.py`**, mirroring everything its console
shows. That exists because the console was for a long time the *only* record:
the lines that say whether a batch was dispatched and whether the box
acknowledged it (`-> dispatch`, `acked` / `NO ACK`, `<- result`) are the ones
that answer nearly every "is it the box or is it us?" question, and they were
visible only to whoever was sitting in front of that window, scrolling away
while anyone else reasoned from symptoms. `DOSD_LOGFILE=` turns it off.

Stop the daemon with Ctrl-C in its window, or `dosctl shutdown` from anywhere
on this machine. The endpoint refuses anything but loopback -- every other
route into dosd exists for the DOS box to reach across the LAN, and this is
the one that must not be.

Check liveness first if anything looks wrong:

```
dosctl status
```

`DOS box: alive, polled <10s ago` is healthy. "STALE" or "never seen" means the
DOS box is off, hung, or the firewall is blocking 8080/8081/8082.

## Commands

```
dosnew NAME                   scaffold projects/NAME/ for a new project
makeinst                      rebuild C:\DosBridgeInstaller (bumps the build number)
makeinst --no-bump            ...without advancing it, for test builds
dosctl clean [--all]          delete regenerable build junk (--all: EXEs too)
dosrun PROG.EXE [args]        push, run on the DOS box, capture stdout, return errorlevel
dospush FILE [FILE...]        stage a file on the Windows side only (see below)
dosdeploy FILE [C:\DEST]      stage AND copy onto the DOS box, verified. default C:\WORK
dospull C:\PATH\FILE          copy a file off the DOS box, byte-exact
dosexec "MEM /C" "DIR C:\WORK" run arbitrary DOS commands
dosrun/dosexec --quiet        ...without echoing the output on the DOS console
dosdrv DRV.SYS [args]         stage a driver, reboot, report whether it survived
dosdrv DRV.SYS --device NAME  ...and fail unless NAME registers as a device
dosreboot [--cold]            reboot and wait for it to come back
dosctl stop                   stop the agent loop (one-way -- see below)
dosctl upgrade                update the DOS box over the wire: tools + agent
dosctl upgrade --tools        only the tools in C:\TOOLS (no reboot)
dosctl upgrade --agent        only C:\AI\AI.BAT (swaps, then reboots)
dosctl upgrade --dry-run      say what would change, touch nothing
dosctl version                what build the DOS machine is running
dosctl verify                 CRC-32 every tool on the box against the build
dosctl status                 liveness check
dosctl shutdown               stop dosd itself (from this machine only)
dospower [status|on|off|cycle]  smart plug, if one is configured
doscap [devices|modes|status]   video capture, if a card is configured
doscap live [--mute]            watch the box live, WITH SOUND (q to quit)
doscap shot [FILE]              one still of the box's REAL screen
doscap rec SECS [--audio]       record it. --shots N pulls stills out
doscap burst N [--every S]      a series of stills, S seconds apart
doscap still REC SECS           pull one frame out of a recording
```

### Where new work goes

**`starter/` is reserved** for the bridge's own tools and worked examples; it is
copied into the installer kits. Anything else belongs in **`projects/NAME/`**,
created with `dosnew NAME`. Never author anything under
`C:\DosBridgeInstaller\` — that whole tree is a build artifact, overwritten
wholesale by `makeinst.cmd`.

Staging is namespaced by project, because `files/` used to be one flat
directory keyed on the filename: two projects that both built a `HELLO.EXE`
silently overwrote each other, last writer winning with no warning. 8.3 leaves
only eight characters, far too few to prefix a project name into, so the split
has to be by directory.

| where the file lives | stages as |
|---|---|
| `projects/mandel/build/HELLO.EXE` | `mandel/HELLO.EXE` |
| `starter/build/HELLO.EXE` | `starter/HELLO.EXE` |
| anywhere else | `local/HELLO.EXE` |

`dosrun mandel/HELLO.EXE` names one explicitly. A bare `dosrun HELLO.EXE` still
works when the name is unique, and is a hard error listing the candidates when
it is not — the ambiguity is the whole point, so guessing would defeat it.
Override the inference with `--project NAME`.

**The DOS side is unchanged.** `C:\WORK` is flat and only ever sees the leaf
name, which stays safe because every job does `IF EXIST <dest> DEL <dest>`
before the HTGET — a same-named binary from another project can never be the
one that runs. `C:\TOOLS` is still flat and still clobberable, so deploying
there is the one place to check the name yourself.

`EXIT0.COM` and `PEND.BAT` stay at the root of `files/` and are fetched by bare
name; references are validated to at most one directory level, with `..`,
backslashes and absolute paths refused rather than normalised.

### Build numbers

`makeinst` increments `installer-src/buildno.txt` on every build and stamps the
number into four places in the output:

```
VERSION.txt              build 1 / built <date> / source <path>
README.md                the heading
server/INSTALL.txt       first line
client/README.TXT        first line (CRLF preserved -- it is read on DOS)
```

`server/VERSION.txt` is also read by `dosd` at startup, so a running daemon
says which packaged build it came from:

```
[13:00:04] DOS Bridge build 1 built 2026-08-30
```

That file exists only in a built installer, so the dev tree prints nothing --
the line appears exactly when it is useful.

**Bump by default.** The number exists to tell two artifacts apart, so the
failure that matters is two different builds both claiming the same one --
never a gap in the sequence. Numbers are free; ambiguity is not.

`--no-bump` is only for a build whose output you are about to throw away, such
as iterating on the packaging scripts themselves. If the artifact could end up
on another machine, let it increment.

### Compilers are not fixed

The bridge only ever needs a path to a `.EXE`, so it does not care what built
one. FPC cross-compiling to `i8086-msdos` is what is set up here and what the
scaffold uses, but a project can use anything that emits a real-mode DOS
binary — Open Watcom on the Windows side, or `TPC`/`TASM` running natively on
the DOS machine (both verified working; see the Borland section). Point the
project's `build.cmd` at whichever, and nothing else in the bridge changes.

`dospush` only stages into `files/` for serving over `/f/` — it does **not** put
anything on the DOS box. Use `dosdeploy` to actually get a file there; it verifies
with `IF EXIST` rather than trusting HTGET's exit code, which is >= 20 even on
success. `dospull --out PATH` controls where the file lands locally.

From `starter/`:

```
build.cmd <name>              cross-compile <name>.pas for real-mode DOS
test.cmd <name>               compile AND run it on the DOS box  <-- the main loop
```

The normal iteration is `test.cmd <name>`. It exits non-zero if any test failed,
so branch on that.

## Tools installed on the DOS box

Built with FPC and deployed to `C:\TOOLS`. Sources in `starter/`. These exist
because the same questions kept costing minutes of round-trips.

**`C:\TOOLS` is currently NOT on the box's PATH.** Checked 2026-08-30:

```
PATH=C:\WINDOWS;C:\;C:\DOS;C:\NETWORK\MTCP;C:\DRIVERS;C:\SOFTWARE\PKZIP;C:\BP\BIN
```

So a bare `dosexec "FPU"` silently does nothing -- COMMAND.COM does not even
get a bad-command message into the captured output. Call them by full path,
`dosexec "C:\TOOLS\FPU.EXE"`, until a `PATH` line is added to `AUTOEXEC.BAT`.
`dosrun` is unaffected: it pushes the binary into `C:\WORK` and runs it there.

```
DSTAT [path]              recursive file/dir/byte totals + top directories
DEVS                      list the DOS device chain
DEVS NAME                 exit 0 if character device NAME is loaded, else 1
HD file [ofs] [len]       hex dump + CRC-32 of any file
SCRAPE [/A] [/R]          capture the TEXT screen and print it through DOS
VSHOT [/K]                capture a mode 13h screen as ASCII art
MEMMAP [/F] [/S]          walk the MCB chain: every block, owner, size
HWINFO                    CPU, BIOS, memory, equipment, ports, video, drives
GTEST                     draw a known mode 13h pattern (for testing VSHOT)
SERIAL [/T] [n /M secs]   UART/RS232 probe; optional type ID and byte monitor
MOUSE [seconds]           exercise the mouse through the INT 33h driver
BENCH [ticks-per-test]    measured cost of the operations that matter here
BEEP [ALERT|DONE|f t n]   PC speaker; ALERT is a ~1.5s siren for attention
IVT [/A] [nn]             interrupt vectors, each attributed to its owner
VIDCHK                    mono or colour? rc 0=colour 1=mono 2=no BIOS opinion
PKTDRV [vec]              find the packet driver, report class/type/name.
                          Read-only: no handle, cannot disturb the link
PKTCAP [secs] [type|ALL]  capture Ethernet frames. Default 5s of ARP.
                          Opens a handle -- read the warning below
ARP addr [-w n]           who has this IP? rc = hosts that answered
ARP -scan a.b.c [-w n]    sweep a /24 and list every host that replies
VMODES [-t] [-d n] [m]    every video mode. -t sets and verifies each one;
                          -d n also DRAWS a pattern and holds it n seconds
                          (needs a human watching). rc = number that failed
FPU [/T]                  coprocessor: fitted, and which? Detect-only by
                          default; /T also runs the arithmetic, which is
                          opt-in because x87 carries WAIT prefixes and WAIT
                          with nothing answering hangs the machine.
                          rc 0=present 1=none 2=present but a test FAILED
MOZART [ticks]            Eine kleine Nachtmusik on the PC speaker (one voice)
AMOZART [ticks]           the same in two voices on an AdLib/OPL2, detected first
FPUPROBE                  coprocessor timing diagnostic: walks the delay
                          lengths and prints the raw words. No FWAIT, so it is
                          safe with or without a coprocessor fitted
KEYHIT                    rc 1 if ScrollLock is on, else 0. 22 bytes, silent;
                          the agent loop runs it once per poll
SCRLOFF                   turn ScrollLock off, keyboard lamp included. The
                          agent runs it as it stops, because the flag
                          LATCHES: an agent that stopped on ScrollLock and
                          left it set stopped again on its first poll after
                          being restarted. Every keyboard-controller wait in
                          it is bounded, so a keyboard that never answers
                          costs a stale lamp and not a wedged box.
                          Verified at the keyboard 2026-09-04, lamp included
KINJ file.KI | /U | /D | /S
                          Resident keystroke injector and screen grabber, so
                          an INTERACTIVE program can be driven and watched
                          from Windows. Hooks INT 16h. /D prints the screens
                          it captured, /U unhooks and frees, /S reports.
                          1582 bytes of NASM; mkkeys.py compiles the scripts.
                          It CANNOT drive anything that reads INT 9 itself
KNET [port] | /T | /S | /U
                          LIVE remote keyboard: you type on Windows, the
                          keystrokes are injected into whatever is running
                          here. Takes a packet driver handle and serves the
                          keys through INT 16h. /T proves the receive path
                          WITHOUT going resident -- always start there.
                          starter/sendkeys.py is the Windows end.
                          Keys must be BROADCAST; see below
NTP [a.b.c.d]             what time does that server think it is? Our own
                          UDP, not mTCP. Read-only -- it never sets the clock
UGET ip name file [POLL]  fetch a file from dosd over UDP. The HTGET
                          replacement. Silent unless -V; honest exit code
UPUT ip file name         send a file to dosd over UDP. The NC replacement
ELAPSED /S | <text>       job stopwatch. /S stashes the tick; otherwise
                          prints <text> with the time since, on ONE row
```

The graphics and sound demos, built from the same tree but not diagnostics:

```
RAYCAST [INT|FPU] [SECS n] [SEED n] [KEYS|PLAY file] [HOLD] [NOPIVOT]
        [QUIET|SPKR] [TEX|FLAT] [M13|COARSE|FINE] [NOSEEK]
                          Wolfenstein-style raycaster with AdLib music. Walks
                          itself round a GENERATED 64x64 maze and prints what
                          it drew, or is driven -- KEYS from the keyboard,
                          PLAY from a file of timed events. SECS goes to 1800
                          now that longer runs see more; raise --timeout to
                          match. SEED is the whole description of the world
FRACTAL [INT|FPU] [ZOOM n] [SECS n]   Mandelbrot, both inner loops
BALLS                     bouncing balls in mode 13h, mono or colour
MATRIX [seconds]          the falling-green-text screensaver, text mode
SCROLLER [SECS n] [SPEED n]   mode X scroller, sprites + AdLib. See SCROLLER.md
SVGATEXT [text]           rotating text; VBE 640x480x256, else mode 13h
GTEST                     mode 13h test pattern, deliberately leaves the mode set
PROFTEST                  exercises the Prof unit's section timing
```

`VIDCHK` duplicates one line of `HWINFO` on purpose: `HWINFO` prints it among
thirty others and cannot be branched on, whereas `VIDCHK` is an external program
so its `ERRORLEVEL` is trustworthy. This card boots mono or colour at random, so
`dosexec "VIDCHK"` is the cheap way to find out which before running anything
graphical. Read `HWINFO` when you want the whole picture; run `VIDCHK` when code
has to decide.

`VMODES` is the answer to "what resolutions does this card really do?", and it
exists because enumeration lies -- in both directions.

It under-reports: `VESACHK` once produced **`modes listed: 0`**, reading as "no
SVGA at all", because it filtered on `BitsPerPixel >= 8` and that boot offered
only 800x600 *planar* modes, which report fewer bits per pixel and vanished
silently. That filter is now a label, not a filter.

It also over-reports what is *unavailable*: on the small-memory boot the card
does not list 640x480x256 at all, yet `4F02h` accepted it when asked. Listing a
mode and being able to set it are separate questions, which is exactly why
`VMODES -t` sets each one rather than trusting the list.

`VMODES` with no argument lists standard BIOS modes 00h-13h plus every VESA
entry with its raw attribute word, so you can see *why* something is or is not
usable. `VMODES -t` sets each one, confirms it with `INT 10h AH=0Fh` (or
`4F03h`), pokes the framebuffer, and restores text mode -- in milliseconds,
drawing nothing.

**`-t` alone proves the BIOS accepted a mode, not that it displays.** For that,
`VMODES -t -d 3` draws a test pattern in every mode and holds it three seconds:
a border showing the visible area, sixteen colour bars, two diagonals, and for
text modes cycling attributes across every cell so a 132-column mode rendering
as 80 is obvious. **A monitor that cannot sync still logs as `OK`**, so this
mode says in its own banner that somebody has to be watching. Pair it with
`BEEP` so you know when to look:

```
dosexec "C:\TOOLS\BEEP.EXE ALERT" "C:\TOOLS\VMODES.EXE -t -d 3" "C:\TOOLS\BEEP.EXE DONE"
```

The pattern is drawn one pixel at a time through `INT 10h AH=0Ch`. That is slow
-- about a millisecond a pixel here, which is why it is sparse rather than
filled -- but it is the only way to draw into CGA's interleaved pairs, EGA/VGA's
four bit planes and VESA's banked windows without per-layout framebuffer code:
the BIOS knows the layout and the caller does not.

Two details make it safe to run remotely:

* **Every line is flushed as it is written.** DOS buffers redirected output and
  drops the buffer if the machine wedges, so an unflushed log would end *before*
  the mode that caused the problem. Flushed, the last line names the culprit.
* **Text mode is restored after every mode, not once at the end.** A hang
  halfway through still leaves a usable screen.

Note `-t` and not `/T`: from the Bash tool a leading slash gets mangled into a
Windows path (`/T` becomes `T:/`). Both spellings work on the DOS side.

`BEEP` exists because several tools need a human at the keyboard at a specific
moment, and a message in a window nobody is watching does not achieve that.
Compose it: `dosexec "BEEP ALERT" "MOUSE 15" "BEEP DONE"`. Keep alerts long —
the first version was a 440ms chirp and went unheard; a second and a half of
two-tone siren works.

`IVT` completes the trio with `DEVS` and `MEMMAP`: the device chain, the memory
map, and the interrupt table. A TSR that hooks an interrupt without registering
a device is invisible to the other two, so this is what finds it. Any vector
pointing below A000 has something resident in its path; it walks the MCB chain
to name the owner.

It is also the quickest proof of how a mouse driver installed. `INT 0Ch` owned
by CTMOUSE means it took the COM1 IRQ4 path — which verifies a serial-mode
install without anyone having to move the mouse.

### Measured performance — check here before optimising

`BENCH` measured on this box (an NEC V30 at 8086 speeds), operations per second:

```
loop + increment    88961      procedure call      46501
16-bit add          72800      shl by CL (8086)   185021
16-bit multiply     58640      shl by imm (186)   206260
16-bit divide       52561      MemW[] to B800      58640
32-bit multiply     10920      REP STOSW to B800  439821
32-bit divide        7280      array[] store       68322
```

The four coprocessor rows print `no coprocessor, skipped` here; see below.

Two ratios explain nearly every performance problem hit so far:

* **32-bit arithmetic costs 5-8x its 16-bit equivalent.** FPC calls software
  routines for `LongInt` multiply and divide. Converting the Mandelbrot inner
  loop from Q10 `LongInt` maths to Q8 with a single `IMUL` was worth more than
  everything else combined.
* **`REP STOSW` beats per-element `Mem[]`/`MemW[]` by 7.4x.** Every `Mem[]`
  access reloads a far pointer. Replacing a per-pixel loop with one string
  instruction is what doubled the bouncing-ball frame rate.

A third ratio, measured on hardware 2026-08-30, is worth knowing before you
reach for `Has186`: the 186-class immediate shift is **only about 11% faster**
than going through CL (206260 vs 185021 per second). Real, but small. Do not
write a gated fast path for a shift alone -- the gate costs more to maintain
than the win buys. Save `Has186` for something that measures better.

Run `BENCH` before theorising about where time goes. Guessing produced two
wrong answers during the graphics work — blaming VBE bank switching and then
call overhead, both of which measured as irrelevant.

### Attribution: the `About` unit

Every program in `starter/` has `About` in its uses clause, and that is all it
takes -- the banner is printed from the unit's `initialization` section, which
FPC runs before the main program body, so the line lands above whatever header
the tool prints for itself:

```
DOS Bridge tools  --  StevenC
=== sysinfo ===
```

One place rather than a `WriteLn` pasted into twenty-nine programs, because a
banner copied twenty-nine times says twenty-nine slightly different things
within a year -- and the one moment it matters is an EXE found on a disk with
no context, which is exactly where the drift would show. Because the string is
printed it is certainly linked, so `HD` on the binary identifies it even if
nobody runs it. Verified: all 29 EXEs carry both `DOS Bridge` and `StevenC`.

Adding it to a new tool is one word in the uses clause. Nothing to call, and
nothing to forget.

### Portability, and the `Cpu` unit

Everything is compiled `-Pi8086` and sticks to the plain 8086 instruction set,
so a binary built here loads on any DOS box. That is deliberate and should stay
that way: a program that will not run on the machine at the other end is worse
than one that runs slower.

`starter/cpu.pas` is how to go faster without giving that up.

```pascal
uses Cpu;

CpuClass   { cpu8086, cpuNecV, cpu186, cpu286, cpu386 }
CpuName    { 'NEC V20/V30', 'Intel 80286', ... }
Has186     { the 80186 instruction-set extensions are safe to execute }
```

**`Has186` is the gate for any CPU-specific code.** The NEC V20/V30 and the
80186 add instructions the 8086 lacks — shifts by an immediate count, `IMUL`
with an immediate, `PUSHA`/`POPA`, `ENTER`/`LEAVE`, string I/O. Executing one
on an 8086 is an invalid opcode. So: write the portable version, write the fast
version, choose between them with `if Has186`, and never delete the portable
one. Emit the non-baseline instruction as `db` bytes — the assembler targets
the 8086 and is right to reject it as source. `BENCH` does this for immediate
shifts and prints both numbers, which is the place to check whether a fast path
is worth writing at all.

The probe runs three tests in an order that matters: FLAGS bits 12-15 to split
8086-class from 286 from 386+, then the undocumented `AAD` opcode to split NEC
from Intel, then shift-count masking to split 8086 from 186. The shift test is
last because sources disagree about whether the V20/V30 masks shift counts, so
the probe never asks it that question. Only the `AAD` step has been run on real
hardware; a 186/286/386 result is unconfirmed.

`SYSINFO` and `HWINFO` both report `CpuName`, so the answer costs one round
trip.

### The math coprocessor

Same unit, same rule, but the failure mode is nastier:

```pascal
HasFpu       { a coprocessor -- or an emulator -- is there }
FpuClass     { fpuNone, fpu8087, fpu287, fpu387 }
FpuName      { 'Intel 8087', '80387 or later', 'none' }
FpuCw, FpuSw { control and status words straight after FNINIT }
```

**An x87 instruction with no coprocessor fitted does not fault on an 8086.**
The CPU decodes the ESC opcode, runs a dummy bus cycle, and carries on — so
the code runs and quietly produces garbage. Nothing reports it. Every tool and
demo in `starter/` therefore stays on the integer path regardless of what is
fitted; `FPU.EXE` is the only program that executes an ESC opcode, and even it
checks `HasFpu` first.

Three things in the probe must not be "simplified":

* **`FNINIT`/`FNSTSW`/`FNSTCW`, never the un-prefixed forms.** `FINIT` and
  friends assemble a `WAIT` (9Bh) in front, and `WAIT` with no coprocessor
  waits on the TEST pin forever. That hangs the box, and over the bridge a hang
  looks like every other hang — it needs hands on the keyboard. FPC emits the
  FN forms verbatim; the probe in the linked binary is
  `DB E3 / B9 14 00 / 49 / 75 FD / DD 3E / D9 3E`, checked byte by byte, no 9Bh.
* **Seed the status word with `5A5Ah`.** With no coprocessor nothing writes
  back, so the seed survives; reading 0 is what proves something answered.
* **Delay between `FNINIT` and the store.** The 8086 does not interlock with
  the 8087 and can reach the store first.

Generation comes from control-word bit 7 — the 8087's Interrupt Enable Mask,
which `FNINIT` sets, giving `03FFh`; a 287 or later dropped the bit and gives
`037Fh`. A software emulator on INT 7 is indistinguishable from silicon here,
and `FPU.EXE` says so rather than overclaiming.

`HWINFO` also decodes equipment-word bit 1, the BIOS's own opinion, and prints
`** MISMATCH` when it disagrees with the probe.

**This box is exactly such a case, confirmed on hardware 2026-08-30.** Its
equipment word reads `4223`, which has bit 1 set -- the BIOS claims a
coprocessor is fitted. `FNINIT` says there is none, and there is none:

```
    coproc bit     : yes   (BIOS opinion; probe says none)
    ** MISMATCH    : equipment word and FNINIT probe disagree
```

Believe the probe. The equipment bit is stamped by POST from a jumper or a
strap and is simply wrong on plenty of clones. This matters because reading
that bit is the *obvious* way to detect a coprocessor and it is what a lot of
period software does -- trust it here and you execute x87 on a machine with no
coprocessor, which on an 8086 does not fault. It quietly computes nothing.

**The 8087 is worth using, and the earlier guidance here was wrong.**
**...and see the raycaster section below, where this conclusion inverted
again once the thing it was compared against got 15x faster.** Measured
2026-09-01, against the integer paths in the same run:

| | |
|---|---|
| 8087 vs **16-bit** integer | a wash — 61661 against 60660 multiplies/sec |
| 8087 vs **32-bit** `LongInt` | **5.6x faster** — 61661 against 10920 |
| 8087 divide vs `LongInt` divide | **5.0x faster** — 34361 against 6916 |
| `FSQRT` | 42460/sec, with no integer equivalent at all |

So: anything using `LongInt` arithmetic is a strong candidate, and gets full
64-bit double precision for free. Anything already in 16-bit fixed point gains
nothing in throughput — but can trade that even swap for far more precision,
**`fractal.pas` now carries both loops**, chosen at run time:

```
FRACTAL                 use the 8087 if fitted, else Q8 integer
FRACTAL INT             force the integer path
FRACTAL FPU             force the 8087 (refuses if none is fitted)
FRACTAL ZOOM 300 SECS 45    deep zoom -- needs the coprocessor
```

Measured on this box: the Q8 path completes all 200 rows in ten seconds, the
8087 path manages 124. **The coprocessor version is slower**, and that is not a
contradiction of the `BENCH` figures above -- the multiply rates are near
identical, but the x87 loop keeps its values in memory and pays for a
load/store per operation, plus an `FSTSW`/`FWAIT` round trip for every escape
test. It buys precision, not speed.

Precision is the whole point of `ZOOM`. Q8 resolves 1/256, so past ~100x the
window is narrower than one fixed-point step and the picture collapses to flat
blocks; the integer path refuses `ZOOM` for that reason rather than drawing a
lie. Two things learned finding a zoom target worth looking at: every point on
the **real axis** is solidly inside or outside the set, so magnifying the cusp
or the Feigenbaum point just fills the screen with one colour (both tried, both
flat black at 200-400x). The structure is on the boundary and the boundary is
**off-axis** -- so zoomed runs use seahorse valley and give up the mirror,
drawing all 200 rows for a picture that is actually worth looking at.

Two caveats that have not gone away. **Gate it on `HasFpu`** — this suite is
built for machines that may have no coprocessor, and x87 arithmetic carries
`WAIT` prefixes that hang hard when nothing answers. And **`FPU /T` is opt-in**
for the same reason: a probe wrong in the optimistic direction turns a
diagnostic into a machine somebody has to walk over to.

### Profiling your own code: the `Prof` unit

### Shared graphics plumbing: the `VGA` unit

**The video card reports a different amount of memory on different boots, and
therefore a different mode list.** This is the second boot-time lottery on this
machine, alongside mono-vs-colour, and it is much bigger. Two boots, same
hardware, nothing reconfigured:

| | one boot | another |
|---|---|---|
| `4F00h` reports | 256 KB | **1024 KB** |
| graphics modes offered | 2 | **18** |
| of those, 8bpp or better | **0** | 14 |
| best available | 800x600x4 planar | 1280x1024x4, 1024x768x8, 640x480x24 |

So `svgatext.pas` asking for VBE 101h (640x480x256) **succeeds or fails
depending on the boot**. It used to exit 1 and draw nothing when the card came
up small, which is why these notes claimed for a while that the demo "does not
run on this box and never has" -- wrong, and wrong in a way that only a second
boot could expose. It now falls back to mode 13h (320x200x256, guaranteed on
any VGA, no banking) and runs either way.

**The rule this forces:** never record a video capability here as a property of
the machine. Probe it at run time, every run. `VESACHK` and `VMODES` describe
*this boot*, not the card. An earlier `VESACHK` reading of "0 modes" was itself
a filter bug -- but even fixed, its answer is only good until the next reset.

`starter/vga.pas` holds the mode 13h helpers the demos share: `SetMode`,
`GetMode`, `Ticks`, `OutB`/`InB`, `DisplayCode`/`IsColourDisplay`,
`ChoosePalette` (the `MONO`/`COLOUR` argument override), `DacSeek`/`DacRGB`/
`DacGrey`, `WaitRetrace` and `FillSpan`. `fractal.pas`, `balls.pas` and
`vidchk.pas` all build on it; `uses VGA` and the `-FUbuild` already in
`build.cmd` is enough.

It exists because those ~60 lines had been copied between two demos and every
fix — the bounded retrace wait, the six-bit DAC, the display probe — had to be
made twice or silently drift. Two things in it are load-bearing and easy to
reintroduce as bugs if you write your own:

* **`WaitRetrace` is bounded.** An unbounded `repeat until port` wedges the
  machine and needs a physical reset if that bit stops toggling. It counts
  give-ups in `RetraceTimeouts` and accepts tearing instead.
* **`FillSpan` is `REP STOSB`, not a pixel loop.** Per-pixel `Mem[]` reloads a
  far pointer every time and measures ~7x slower; this is what doubled the
  bouncing-ball frame rate.

`fractal.pas` is colour-only by choice. A colour ramp is *not* automatically
safe on a mono display — the monitor sums R+G+B, so two different colours can
land on the same grey — so on a mono boot it looks muddy rather than merely
desaturated. Check with `VIDCHK` first. `balls.pas` still carries both palettes
and picks at run time, which is the pattern to copy for anything that has to
work whichever way the card came up.

### Smooth scrolling: mode X, and why the frame rate is quantised

`starter/scroller.pas` is a side-scrolling landscape with sprites and AdLib
music, and `starter/modex.pas` is the reusable half: unchained
320x200x256 with a virtual screen wider than the display. Verified on hardware
2026-09-01 -- 2096 frames in 30.00s, **69.8 fps, one vertical refresh per
frame, zero late frames**, which is as fast as a 320x200 VGA goes.

**A software scroller cannot be smooth on this box, and the arithmetic says so
before you write one.** A mode 13h frame is 64000 bytes, which `BENCH` puts at
73ms -- 13 fps before a single pixel has been *decided*. So the scroll has to
move to the CRTC: tell the card the picture is 1024 pixels wide while the
monitor shows 320, then move the window with the Start Address (CRTC 0Ch/0Dh)
and the Attribute Controller pixel pan (index 13h). Start address steps four
pixels, pixel pan supplies the remaining nought-to-three, and the whole frame
costs five OUTs.

Unchaining is four registers, and `Enter` reads all four back rather than
trusting them -- a card that ignores one leaves a picture that is *skewed*
rather than absent, which is a confusing way to spend an afternoon:

```
Sequencer 04h  = 06h        Chain-4 off, keep Extended Memory + sequential
CRTC      14h  bit 6 = 0    doubleword off
CRTC      17h  bit 6 = 1    byte mode on
CRTC      13h  = VW/8       Offset: 128 for a 1024-pixel virtual width
```

Two consequences that are easy to miss:

* **Solid fills get *cheaper*.** With all four planes enabled one byte write
  sets four horizontal pixels, so a span is a quarter of the STOSBs mode 13h
  needs. What gets dearer is anything vertical or unaligned, which has to be
  done a plane at a time.
* **There is no room left for a back buffer**, and that is a real trade, not
  an oversight. At 1024 wide the picture is 204800 of the card's 262144
  bytes. Hardware scrolling and page flipping compete for the same memory and
  on a wide world the scroll wins easily -- but it means sprites are erased
  and redrawn in place, so they can shimmer when the beam catches one
  mid-update. The scroll itself never tears; that is the CRTC.

**Wrapping needs no repainting at all** if the geometry is chosen for it. Make
the world 704 columns and the last 320 a copy of the first 320: `704 + 320 =
1024`, so at scroll 703 the window shows the end of the world followed by its
beginning and the scroll can snap back to 0 with the picture unchanged.
Nothing is ever drawn as it comes on screen.

**Parallax is not available.** One start address moves the entire screen. CRTC
line compare gives a second region, but that region is pinned to address 0 and
cannot be panned horizontally, so it can only ever be a *static* band. Depth
has to come from sprites, which are drawn per frame and can drift at any rate.

#### The frame rate is 70.1 / N, and nothing in between

This is the part worth internalising before optimising anything that syncs to
the display. Waiting on the vertical retrace means a frame occupies a whole
number of refreshes:

```
N = 1   70.1 fps    needs the frame under 14.27 ms
N = 2   35.0 fps                      under 28.54 ms
N = 3   23.4 fps                      under 42.80 ms
```

So shaving 10% off usually buys **nothing at all**, and then one more percent
doubles the rate. Every step of tuning this demo, measured on hardware:

| | work/frame | N | fps | |
|---|---|---|---|---|
| 6 sprites, blitter as a hand pixel loop | ~36 ms | 3 | 23.4 | steady |
| 6 sprites, blitter as `REP MOVSB` | ~24 ms | 2 | 35.1 | steady |
| 6 sprites + music | ~19 ms | 2/3 | 33 | **juddering** |
| 5 sprites + music | ~14.5 ms | 1/2 | 56 | **juddering** |
| 4 sprites + music | ~11.5 ms | 1 | 70.4 | steady |

**56 fps is worse than 35 fps, and this is the trap.** A frame time landing
*between* two multiples of 14.27ms gives a respectable-looking average and a
picture that stutters, because consecutive frames are held on screen for
different lengths of time. An average frame rate cannot show you that. Count
the frames that arrive at the flip with the retrace already under way --
`FlipLate` in `modex.pas`, three lines -- and check *that* after any change.

`PROF` is what found the blitter: it reported `draw` at 60% of the frame while
the scroll cost nothing measurable. Guessing would have gone after the scroll.
But note `Mark()` is called ~13 times a frame there and its own cost lands
inside the sections, so a profiled frame is materially slower than a real one.
**Use `PROF` for ratios and take absolute frame times from a run without it**
-- believing the profiled number here hid a whole refresh boundary for two
rounds of measurement.

The fix is the ratio already recorded above, applied to sprites: the sprite
data is **deinterleaved into the four column groups** `c mod 4`, because within
one group the four columns land on four *consecutive* addresses in one plane,
which turns a row into one `REP MOVSB`. Transparency comes from a precomputed
(first, count) run per group-row instead of a test per pixel, so the fast path
stays a string instruction. Copy that pattern for any mode X sprite.

Save and restore of sprite backgrounds use write mode 1 (VRAM-to-VRAM through
the latches), where one byte moved carries four pixels across all four planes
-- four times cheaper per pixel than drawing them.

**`VSHOT` cannot photograph an unchained mode.** It reads A000 linearly, which
is meaningless once the chain is broken, so `scroller` prints its own ASCII
thumbnail by reading pixels back through Read Map Select. Anything written for
mode X needs its own read-back if it is to be checkable over the bridge. Rank
such a thumbnail by a **depth-ordered grey ramp, not by true luminance** -- a
colour palette is chosen for hue, and ranking it by brightness turns a legible
picture into noise.

### The raycaster, and where the time actually goes

`starter/raycast.pas` is a Wolfenstein-style raycaster in mode 13h. It walks
itself round a 16x16 maze -- there is nobody at the keyboard over the bridge --
and prints its own stats, the maze with the cells it visited, and an ASCII
thumbnail read back out of A000, so the whole run is checkable from Windows.

Three `BENCH` numbers shaped it more than the raycasting did:

```
32-bit multiply    10920/sec      REP STOSW to video   439821/sec
32-bit divide       7280/sec      per-pixel MemW[]      58640/sec
```

Which forces four decisions:

* **No divides in the DDA.** The textbook algorithm divides twice per column
  for `deltaDist = 1/|rayDir|`. Both depend only on the ray's *angle*, so they
  are precomputed into a 1024-entry table and the per-column cost becomes a
  lookup. 1024 divides once at startup against 640 every frame.
* **Q8, not Q10.** `IMUL` leaves the product in DX:AX and a `>>8` of that is
  two register moves -- `AL` takes `AH`, `AH` takes `DL`. A `>>10` needs a
  six-round `shl`/`rcl` chain, because the 8086 has no 32-bit shift. Same
  reasoning as `fractal.pas`.
* **One divide per column survives**, the perspective divide `height = k/dist`.
  That is the only thing left for a coprocessor to win, and it is exactly what
  the `FPU` path replaces -- three x87 instructions, `FILD`/`FDIVR`/`FISTP`.
  Everything else is identical between the two paths.
* **The blitter never touches a pixel.** Adjacent columns with the same top,
  bottom and colour are coalesced into runs, and each run is drawn as
  rectangles of `REP STOSB`. Facing a flat wall the entire screen collapses
  into a handful of rectangles; at an angle the runs narrow and it degrades to
  something close to per-column fills.

**Where the frame actually goes**, measured on the V30 with `NODRAW` and
`NOCAST` -- which run the loop with one half switched off, and which corrected
two wrong guesses:

| | |
|---|---|
| `FINE`, 320 rays at 1 px | 345 ms (2.9 fps) |
| default, 160 rays at 2 px | **238 ms (4.2 fps)** |
| &nbsp;&nbsp;casting | 79 ms |
| &nbsp;&nbsp;drawing | 159 ms -- of which 78 is the band clear |
| `BLOCKY`, 80 rays at 4 px | 182 ms (5.5 fps) |

**The band clear is the floor, and it is memory bandwidth, not code.** Two
full-screen rectangles are 64000 pixels; `BENCH` puts `REP STOSW` at 439821
words a second, which predicts 73 ms and measures 78. Nothing rearranges that
in mode 13h -- the screen has to be written once and that is what writing it
once costs. Everything below is about the other 160 ms.

Three things in that table are worth keeping:

* **The 8087 is worth 13 ms, about 5%.** That is the entire perspective
  divide -- 160 a frame, from a software 32-bit divide at 7280/sec to three
  x87 instructions at 34361/sec. It is a small share precisely because
  everything else was arranged to avoid 32-bit arithmetic. This is not a demo
  that needs a coprocessor, and it says so.
* **Casting was the biggest single cost, not the blitter.** That is the
  opposite of what it looked like, and only `NODRAW` showed it. The fix was
  removing procedure calls from the DDA -- a flat byte map indexed by a
  running offset instead of `CellAt` on an array of `ShortString`, and 16-bit
  positions instead of `LongInt`, which had been putting a 32-bit shift and
  AND in every column of every frame.
* **Hoisting beat micro-optimising, by a lot.** `MX`, `MY`, the grid index
  and both fractional positions were computed inside the per-column cast --
  two shifts, a multiply and two ANDs, 160 times a frame for an answer that
  depends only on where the camera is. Moving them to a once-per-frame
  `CamPrepare` took casting from 93 ms to 79. By contrast, unrolling the
  column blitter's row loop by two -- the obvious micro-optimisation, and the
  one that looked most promising -- was worth about 2%.
* **Doubling the rays costs 101 ms, almost exactly the extra casting.** Once
  ceiling and floor became bands, the ray count stopped affecting the fill at
  all -- so the first version's claim that 160 rays were "roughly three times"
  faster stopped being true the moment the bands went in. Measured claims go
  stale when the thing around them changes.

### Mode X, page flipping and the walk: 4.2 to 12.0 fps

Measured on the V30, all on the same maze and the same 30-second tour:

| | fps | |
|---|---|---|
| the old default: chained mode 13h, 160 rays | 4.2 | ceiling, then floor, then walls, visibly |
| mode X, 80 rays, single page | 8.6 | |
| **mode X, 80 rays, triple buffered** | **12.0** | nothing visible but finished frames |

**2.9x on the default path, and the tearing is gone.** Three separate changes,
each measured, and the one that mattered most to look at was not the one that
bought the most frames.

#### Page flipping is the answer to "it draws the floor then the walls"

That complaint is exact, and it is not a rendering bug: the frame really is
assembled ceiling-first, then floor, then walls over the top of both, and at
four frames a second you watch it happen. **A chained 320x200 screen cannot
be double buffered** -- it is 64000 bytes and only one of those fits in the
64K window at A000, so there is nowhere to build the next frame out of sight.
Every mode 13h demo here has the same property; this is just the first one
slow enough for it to show.

Unchained, a page is 320x200/4 = 16000 bytes a plane against 65536 fitted, so
**three** pages fit. Three rather than two deliberately: with two, the page
drawing moves on to is the one still being displayed until the next retrace,
so the flip has to *wait* for that retrace -- up to 14 ms out of a frame
lasting 83. With three, the page we step to is two flips old and certainly
not on screen, so the flip waits for nothing and costs two OUTs. `FlipWait`
is reported and reads **0**.

The start address is written in the units `modex.pas` already uses for the
scroller -- one address is one byte a plane, four pixels, which is why
`ShowAt` there does `PixX shr 2`. Both halves go in during active display so
the CRTC cannot latch an address that is half old and half new; there is
deliberately **no** wait after them.

#### Only clear the rows that are stale

Each page carries the top and bottom row its own previous frame put walls
into. Everything outside that band still holds the ceiling or floor colour it
was given two frames ago, so the clear is that band and not the screen. A
corridor fills most of the screen with wall and saves little; an open room
leaves a thin band and saves nearly all of it.

#### `REP STOSB` for one byte is the wrong instruction

The wall slices went through the general rectangle fill, which sets up a
`REP STOSB` **per row**. A four-pixel-wide column in mode X is *one byte* a
row, so that was paying about 20 cycles of string setup to move a single
byte, for every wall on the screen. A plain store plus a stride, unrolled by
two, is about half the cost. Full-width bands went the other way: rows are 80
bytes and the stride is 80, so a full-width rectangle is one unbroken block
and can be a single `REP STOSW` with no row loop at all.

Drawing went from ~76 ms a frame to ~47 ms, which made casting the bigger
half and sent the next round of work there -- see the section below, which
took another 14% off it. Where the frame stands now:

| | |
|---|---|
| `NODRAW` (casting only) | 29.4 fps, so ~34 ms |
| whole frame | 12.3 fps, so ~81 ms |
| therefore drawing | ~47 ms |

Drawing is close to memory bandwidth in mode X and there is not much left in
it: the screen is 16000 bytes, a contiguous `REP STOSW` moves one in about 7
cycles and a strided store about 18, and most of the frame is already the
cheaper of those.

#### The walk was looping, and more time did not help

The tour is the point of the demo and it was **saturating**. The original went
straight until a wall stopped it, then turned right until something opened --
which is not a wall follower and does not explore. Measured: **22 cells of 256
in twelve seconds and 24 in thirty**. Tripling the run bought two cells.

It now walks cell to cell and picks the open neighbour it has visited *least*,
with a penalty on reversing. That cannot settle, because arriving somewhere
raises its count and makes it the least attractive way back, so the walk is
always pushed at the part of the maze it knows worst. Four comparisons a cell,
no queue and no stack.

| | old | new |
|---|---|---|
| 30 seconds | 24 cells | 30 |
| 60 seconds | -- | **65** |

**Linear in time rather than flat**, which is the property that was broken.
The default run is 30 seconds rather than 10 for the same reason: now that
longer runs see more, they are worth having.

**All of that was then outgrown by a bigger world -- see the next section.**
The rule above is a good LOCAL rule and it does not scale, which is worth
knowing before writing another one like it.

One tuning note that is easy to get backwards. Turning *while* moving cuts the
corner, and cutting the corner runs the camera into its own wall probe -- 44
of 85 cell choices were being thrown away and re-made. Pivoting on the spot
through the wide part of a turn dropped that to 9. It costs travel time at
every corner, so the turn rate is what decides how much of the maze a run
actually reaches; it is not a cosmetic number.

### A generated 64x64 maze, and a tour that seeks frontiers

The map was a hand-written 16x16 literal. It is now generated at 64x64 --
sixteen times the area, 2173 open cells against 116 -- and the tour that
walks it had to be replaced, because the greedy rule above stopped working
at that size rather than merely getting slower.

**64 is a ceiling, not a round number.** Positions are Q8 and held in an
Integer on purpose (a LongInt camera position put a 32-bit shift and AND in
every column of every frame). 64 * 256 = 16384, comfortably inside an
Integer; 128 cells would be 32768 and would not.

**The frame rate did not change.** 10.4 fps against 10.5 on the old map,
held over a ten-minute run: a
maze has short sightlines whatever its overall size, so the DDA still
averages 2.9 steps a ray. An open arena of the same size would not be free
-- it is the topology that is cheap, not the dimensions.

#### Two things broke that a smaller map had been hiding

* **The DDA's side-distance compare was signed and had to become unsigned.**
  Side distances accumulate in a 16-bit register, and the worst case is a
  ray crossing the whole world (90 cells, 23040 in Q8) that then takes one
  step on the clamped axis: 23040 + 24000 = 47040. That is a positive Word
  and a NEGATIVE Integer, and `jge` on it steps the wrong axis for the rest
  of the ray. On 16x16 the sum could not reach 32767 whatever the maze
  looked like, so the signed compare was correct there **by accident of the
  size** and nothing in the code said so. `jae` costs the same. `DD_MAX`
  came down 32000 to 24000 in the same change, which is 93 cells against a
  90-cell diagonal -- it only has to be big enough that a near-axis ray
  leaves the world before that axis could step again.
* **The Y-step stride is unrolled.** `SIy = StpY * MAPW` was four `shl ax,1`
  for MAPW=16 and is six for 64. Nothing can check that, so there is a
  `{$IF}` in front of `CastColumn` that refuses to build if `MAPSHIFT`
  changes. Unrolled and not `shl ax,cl` because a shift by CL is ~8 + 4 per
  bit on an 8086: 32 cycles against 12, for two bytes of fetch.

#### The tour: greedy locally, flood fill globally

The greedy rule picks the least-visited open neighbour. When it has nothing
unseen adjacent, the walk flood fills (breadth-first, over open cells) to
the nearest cell it has not seen this sweep and follows the route there.

**AND IT IS WORTH ALMOST NOTHING, WHICH IS NOT WHAT THIS SECTION SAID
FIRST.** `NOSEEK` turns the fill off and leaves the old rule on its own, so
the two run in one binary on one maze. That switch exists because the first
draft claimed a 42-to-154 improvement for the flood fill that **was not the
flood fill at all** -- the 42 came from an earlier build that also carried
the overshoot bug below and a slower walk, so three changes were being
credited to one of them, and the comparison was against a different binary
on a different maze. Measured properly:

| | 60 seconds | 10 minutes |
|---|---|---|
| greedy only (`NOSEEK`) | 154 of 2173 | 1261 |
| frontier seeking | 154 | 1300 |

**Nothing at one minute and 3% at ten.** The least-visited rule grades on
the visit COUNT, and that gradient turns out to be a decent global heuristic
on its own: it keeps pushing at whatever the walk knows worst, so it rarely
needs rescuing.

**It is kept, and the reason is not the 3%.** The greedy rule has no
termination property -- when the last unseen cell is across the maze,
nothing in a four-neighbour comparison can aim at it, so a `NOSEEK` run
cannot finish a sweep and the `full sweep` line can only ever say "not
completed". The fill can. That claim is **reasoning and not measurement**:
both runs above stop around 58%, which is well short of the endgame where
the difference would have to show, and a run long enough to reach it has not
been done. Treat the completion guarantee as untested until it has.

**It is not run every cell, and that is a cost decision.** A full fill is
~2000 open cells at four neighbours each, which `BENCH`'s 11 us per loop
iteration puts at about 80 ms -- one whole frame. Cheap at the 124 times a
ten-minute run actually needs it; ruinous at the three times a second the
walk chooses a cell. The counter is in the report (`flood fills : 124`) so
the assumption is visible rather than inferred.

Scratch for it is on the heap, not in DGROUP: three arrays of one entry per
cell is 16 KB on top of the ~40 KB of angle and texture tables already
there, and the heap has half a megabyte.

`Visited` holds the SWEEP NUMBER a cell was last walked in rather than a
count, so finishing the maze is one increment of a generation counter
instead of a pass that clears 4096 bytes. That matters because the coverage
report wants to know what was EVER reached, and clearing would throw exactly
that away. A tour that reaches the last cell starts another sweep rather
than stopping -- a demo standing still looks identical to a demo that
crashed, and over the bridge nobody can see which.

#### The overshoot, and why going faster made it worse

The tour is locomotion-bound, not decision-bound: a cell costs 256/PERSEC to
cross plus 256/TURNSEC to turn through a right angle, and in a *generated*
maze almost every cell is a corner where the old hand-drawn map had long
straight corridors. So both constants went up, 700 to 1150 and 640 to 1400.

That made it **worse**, and the way it got worse is the diagnosis:

| | cells chosen | re-chosen at a wall |
|---|---|---|
| PERSEC 700 | 87 | 24 |
| PERSEC 1150 | 108 | **48** |

Arrival is tested as "at or past the centre", so a step lands up to a whole
step BEYOND it -- 0.45 of a cell at that speed and this frame rate. If the
next move is a turn, that is a camera sitting a third of the way into the
wall it is turning away from, the probe refuses to move, and the cell is
chosen again from a position it can never leave. **The faster it walked the
worse it got, which is the signature of a per-step overshoot rather than of
the speed itself.** Clamping the step to the distance remaining makes
arrival exact at any speed, and took re-choosing to **zero**.

Two more things moved with it. Pivoting now continues until the heading is
within 17 degrees rather than 56, because a carved maze turns at nearly
every cell. And braiding -- knocking interior walls back out after the carve
-- went from 16% to 25%: a recursive backtracker makes a PERFECT maze, one
route between any two cells, which is the wrong shape for something whose
job is to be walked and looked at. Every junction is a fork into a dead end
and the view is a wall two cells away in every direction. A braided wall is
also a straight run, so it buys back pivot time as well as making loops.

#### The camera walked faster the faster it rendered

Found while trying to A/B the walk with `NODRAW`, and it is why that
comparison had to be thrown away and re-run: **398 cells with `NODRAW`
against 154 with the drawing left in**, over the same 60 seconds on the same
maze, for a walk whose entire design is that it is paced by the BIOS tick
and not by the frame count.

One line, and it had been there since the walk was written:

```pascal
if DTicks < 1 then DTicks := 1;      { Now - Last, in BIOS ticks }
```

The BIOS tick is 18.2 a second. **Below that rate the clamp never fires**,
because every frame spans at least one tick -- and this renders at about
ten, which is why it survived. Above it, `Now - Last` is frequently 0, the
clamp turned that into a whole tick, and the camera took a full tick of
movement on every frame: the tour walked at the FRAME rate rather than at
`PERSEC`. It is `if DTicks < 1 then Exit` now, so motion happens 18.2 times
a second however many frames are drawn.

Two things generalise:

* **It lived exactly where it would be quoted.** `NODRAW` and `NOCAST` are
  the measurement modes, they are the only things here that run above 18
  fps, and so they were the only place it could ever show. A correctness bug
  scoped to the diagnostic path is worse than one in the main path, because
  its output is what gets written into notes like this one.
* **Fixing it broke the thing it had been hiding.** With the walk correctly
  paced a `NODRAW` frame moves nothing on 99% of frames, so the pivot cache
  hands back the previous columns and the loop reaches **2083 fps casting
  nothing at all** -- an honest number and a useless one. `NODRAW` now turns
  the pivot cache off and casts every frame, which is what the figure meant
  historically anyway, back when the clamp was moving the camera on every
  frame by accident. It reads 41.6 fps.

The check that it is fixed is the one thing that must not depend on the
frame rate: **2.5 cells a second at 41.6 fps against 2.57 at 10.4.**

#### The maze is generated, so SEED is the whole description of it

4096 characters of literal is not something anyone can check by eye, and a
generator gives a different world out of the same binary for free -- which
is what makes a performance number reproducible AND lets a bad case be
re-run. The seed is reported with the results. Note the value reported is
the seed AS GIVEN and not the live LCG state, which the carve has advanced
a few thousand times by then: a reported seed that does not reproduce the
maze is worse than not reporting one.

### A fault suspected in the pivot cache, and not found

Worth reading whole, because the argument for the fault is a good one and
will occur to the next person too -- and because acting on it shipped a
3.4% regression, briefly, to fix something that measures as absent.

**The report.** From somebody at the keyboard driving with `KEYS`: *"the
rendering is kinda funky when we are not at perfect 90 degree angles --
walls and stuff like corners render really strange looking."*

**The argument.** The cache shifts six column arrays, and they do not hold
rays. They hold heights, extents, texture offsets and texel steps, every one
of which comes through

```
Perp = RayD * ColCos[X]
```

and **`ColCos` is indexed by SCREEN COLUMN** -- it is the fisheye correction
for how far that column sits off the centre of view, running 256 in the
middle down to 225 at the edges (Q8, cosine of 28 degrees). The world ray
really does move from column `X+K` to column `X`, and its offset from the
middle of the screen changes when it does. So a cached column looks like it
must be carrying a height computed with `ColCos[X+K]` into a place where
`ColCos[X]` applies: up to 12% wrong, across half the screen, every time the
camera turns on the spot. That predicts the reported symptom exactly --
face-on every column is nearly the same height and 12% is invisible, while
on an oblique wall it bends the perspective.

**The measurement says no.** Camera turned 90 degrees on the spot in a
corridor then held still, so every column on screen came out of the cache
and none was re-cast (`1952 of 2160 reused`):

| | |
|---|---|
| `ColTop` and `ColBot`, cached against freshly cast | **identical, all 80** |
| ASCII thumbnail | byte-identical |

`ColOfs` differed by a constant 8 in every column, which is the texture heap
block landing at a different offset within its paragraph between two runs --
not a rendering difference, and the identical thumbnails confirm it.

So the argument is wrong somewhere and **the flaw in it has not been
found.** The cache is back on by default; `NOPIVOT` disables it, and that
stays because it is the only one-command A/B available to somebody who can
actually see the screen.

#### The instrument built to settle it is NOT validated

`PIVCHK` re-casts every column from the camera state a run ended in and
reports how far the frame had drifted. No confound in it -- it compares a
frame against a re-cast of itself rather than against another run. `PIVBAD`
mis-shifts by one column on purpose so that `PIVCHK` can be shown to catch
something.

**`PIVCHK` read zero for `PIVBAD` as well**, which does not mean the cache
is sound; it means the reading was saturated. Every scripted viewpoint tried
ended with the camera close to a wall, where the perspective divide gives a
height over 200 and **every column clips at row 0**, so no difference can
show. A per-column dump reading `0 0 0 0 0 0 0 0 0 0` is what exposed that
-- the headline number on its own would have been quoted as a null result.

If this is picked up again: get a viewpoint looking down a long corridor at
an oblique angle, and require `PIVBAD` to read **non-zero** there *before*
putting any weight on the cache reading zero. Same rule the frame-stall work
had to learn -- a measurement is worth nothing until the instrument has been
shown able to fail.

#### What the symptom is: SEEN, on the real screen

Settled on 2026-09-05 by pointing the capture card at it -- which is what
that feature is for, and the first time anybody could look at this from
Windows rather than at an ASCII thumbnail.

**Mode X casts 80 rays across 320 pixels, so every ray paints a column four
pixels wide.** Head-on that is invisible, because neighbouring columns are
the same height. Obliquely the depth changes fast across the screen, so the
wall becomes a **four-pixel staircase** -- and in the captured frame it is
plainly there: the top edge of every oblique wall steps in 4-pixel jumps,
and each mortar line is broken into 4-pixel segments rather than running as
a straight diagonal. The step size matches the ray width exactly.

That is a resolution artifact, not a bug, and it is consistent with the
pivot-cache measurement above rather than an alternative to it.

**`COARSE` is only half an A/B, and the reason is a hard coupling in the
source.** It halves the column to 2 px and the geometry edges do visibly
smooth -- but `raycast.pas` line 3542 reads

```pascal
if not UseX then Textured := False;
```

and `COARSE` sets `WantX := False`. So a `COARSE` frame is **flat-shaded and
always will be**: it can show the wall-edge half of the symptom and can never
show the texture half. Comparing the two and concluding "textures look
different" would be reading a code path, not a rendering difference.

Doing this properly needs textures at 2 px a column, which today is not a
switch -- it is lifting the mode 13h restriction on the texture blitter.

### Driving it: `KEYS`, `PLAY`, and `starter/kbd.pas`### Driving it: `KEYS`, `PLAY`, and `starter/kbd.pas`

`RAYCAST KEYS` puts a person at the controls -- W/S or the arrows to move,
A/D to turn, Q/E to strafe, Shift to run, Esc to quit.

**The BIOS key buffer cannot do this job, and that is not a performance
argument.** Every tool here that has wanted the keyboard so far wanted a
KEYSTROKE -- one answer to one question -- and INT 16h serves that perfectly
well. A camera wants key STATE: walking forward while turning left is two
keys held at once, and the BIOS offers neither fact. It offers a queue of
characters, gated by the typematic delay (about half a second before a held
key repeats at all) and with no concept of a release. Drive a camera from it
and the first half second of every movement is one lurch and then a pause,
which reads as a dropped frame rather than as input.

So `starter/kbd.pas` hooks INT 9 and keeps a byte per scancode. The handler
is four instructions; everything careful in the unit is about giving the
vector back.

* **It chains rather than handling the keyboard itself.** Not chaining is
  less code and it is tempting. It also means acknowledging the keyboard
  controller by hand, and the correct acknowledgement differs between XT and
  AT class machines -- get it wrong and the keyboard is dead until somebody
  power cycles the box, which here means somebody walking to it. The BIOS
  already knows which machine this is. Chaining also keeps the BIOS key
  buffer, the lock LEDs, and **the keyboard flags byte at 0040:0017**
  working -- which is where ScrollLock lives, and ScrollLock is how the
  agent loop is stopped.
* **`ExitProc` is hooked before the vector is taken.** Same rule as
  `NetClose` and `release_type`: what gets left behind is a far pointer into
  memory DOS is about to hand the next program, and the next keystroke jumps
  into it. An explicit call at the end of the main program covers the happy
  path, which is not the one that needs covering. The exit hook goes on
  first, so there is no window in which the vector is ours and nothing is
  arranged to give it back.
* **FPC's `interrupt` directive does the hard part**, verified against the
  generated assembly rather than assumed: it saves ax bx cx dx si di ds es,
  **loads DS from DGROUP** -- which is the trap that makes hand-written
  handlers hard, and what `pktcap.pas` has to patch by hand -- sets up BP,
  and ends in IRET.
* **The chain is `call far [P]` through a `Pointer`, not through two Words.**
  It reads four contiguous bytes as offset-then-segment. Two separate Word
  variables read as the same thing and are not guaranteed to be laid out
  adjacently.

#### `PLAY`: the same movement code, tested with nobody at the keyboard

An interactive mode that only a person can exercise is one that is verified
by hope. So the keyboard and a script file fill in the **same array of
intentions**, and the movement code cannot tell which:

```
dosexec "C:\TOOLS\RAYCAST.EXE PLAY C:\WORK\WALK.TXT SECS 20"
```

`starter/mkwalk.py` writes one: `python mkwalk.py S2 E6 S6 E4` emits the
timed events for "south two cells, east six, south six, east four". Verified
on hardware -- the camera walked exactly that route, 19 cells, and stopped
on its own `+QUIT`.

**A script asks for a HEADING, not for a turn key held down, and the frame
rate is why.** The obvious way to turn a corner in a timed script is to hold
RIGHT for as long as a right angle takes. It cannot be made to work: a turn
is applied once a FRAME, this renders at about ten frames a second, and
TURNSEC puts 70 angle units in each of them -- so a 256-unit right angle is
3.66 frames and lands anywhere up to **25 degrees** past where it was aimed.
Over the six cells after the corner that is most of a cell of drift and the
camera grinds along the wall. `+SOUTH` turns to an absolute heading using
the same short-way-round arithmetic the tour uses, and suppresses movement
while the swing is wide, for the same reason the tour pivots.

`mkwalk.py` derives its timing from `MOVESEC` and `TURNSEC` rather than
having numbers typed into it, because those two are the constants most
likely to be tuned again -- they changed twice while this was being written
-- and a script carrying the old ones does not fail. It walks into walls and
produces a plausible-looking bad tour.

#### What is verified, what needed a person, and what froze

Over the bridge: the hook installs, the run completes, and `IVT 9` reads
back **the same `13F3:0045` it did before**, so the vector is given back.
The scripted path is verified end to end.

**The chain itself is not**, and cannot be from here: it only runs when a
key is actually pressed, and there is nobody at the machine. Every run from
Windows installs the hook and then never executes it once. Same shape as
`SCRLOFF`'s keyboard lamp, which also needed somebody standing there.

**`KEYS` froze the machine once at the keyboard**, hard enough to need a
reboot, and worked after it. Not reproduced. The handler is the suspect
precisely because it is the one path here the bridge cannot exercise. Three
things changed in response, and none of them is a fix:

* **The vector is taken one statement before the frame loop**, not before
  the table builds. It used to be live across half a second of texture
  baking, the palette load and the mode set, for no benefit at all. A hook
  is a liability for exactly as long as it is installed.
* **`Output` is flushed before anything that could hang.** All that was on
  screen after the freeze was the attribution banner, which says nothing
  about where it stopped -- FPC buffers `Output`, so everything printed
  after it was still in the buffer when the machine died. `vmodes.pas`
  already flushes every line for this exact reason and the lesson did not
  travel. There is now also a `maze built :` line between the builds and the
  mode set, so a stall has somewhere to stop: that line still showing means
  the palette, the unchain or the hook; a graphical screen means it reached
  the frame loop.
* **The read-then-chain order was left alone, deliberately.** Reading port
  60h clears the controller's output-buffer-full flag, and a BIOS that tests
  that flag before reading could decide there was nothing to do -- a
  plausible hang. Chaining first and reading afterwards avoids that and
  breaks differently: the BIOS talks to the controller for the lock-key
  LEDs, so the data register would hold an ACK rather than a scancode, and a
  controller that advances on the BIOS's read would put every key one
  behind. **The current order is observed working on this machine; the other
  is a theory.** Do not swap them without a machine in front of you.

### Driving an interactive program: `KINJ.COM`

**Built and verified on hardware 2026-09-05.** `starter/kinj.asm`, 1582 bytes,
with `starter/mkkeys.py` to compile scripts and `starter/session.txt` as a
worked example.

```
KINJ file.KI    load a script and go resident (reloads if already there)
KINJ /U         unhook and free
KINJ /D         print the captured screens as text
KINJ /S         resident? how many keys sent, how many screens grabbed
```

The proof is an exit code rather than an eyeball: `CHOICE /C:AB /N` was driven
with a script that answers `B`, and **`CHOICE` returned errorlevel 2** -- its
own report that B was chosen, not our echo of it.

#### Why it has to be resident, and why the script is loaded up front

A job is a batch of commands run one after another, and **DOS is
single-tasking**: while the target runs, nothing else on the box does. So a
keystroke cannot be delivered by another program and a screen cannot be read
by one either -- there is no "meanwhile". The only code that runs during
somebody else's program is an interrupt handler.

**DOS is also not reentrant**, so the handler cannot open a file to read the
next keystroke or write a capture out. Both halves are solved the same way:
the script is read into resident memory at install time, while we are still
an ordinary program, and captures are buffered in resident memory and written
out by a later invocation. Nothing in the handler touches DOS at all.

#### INT 16h, and why the obvious design is the wrong one

The natural injector hooks the timer and stuffs the BIOS keyboard buffer on a
schedule. **Hooking INT 16h is strictly better**: no timing to get right, no
15-entry ceiling, and no race with the target draining the buffer, because
the keystroke is manufactured at the moment it is asked for. It is also less
code -- a switch on the function number. 00h/10h consume a key, 01h/11h peek
without consuming, everything else chains.

Returning "no key" from a peek means clearing ZF **in the caller's flags on
the stack**, not in the live flags, which the IRET discards.

#### Snapshots are taken when the program asks for a key

Which is exactly the moment worth photographing: it has finished drawing and
is waiting. No timer, no polling, nothing to race. `SNAP` fires at the next
INT 16h call, the handler copies the character plane out of B800 (or B000 --
the mode is read at the time rather than assumed), and `/D` prints it
afterwards. Six screens, characters only: an ASCII grab has no use for the
attribute plane.

**`SNAP` had to be made to obey `PAUSE`.** Without that it fired on the very
first poll after install, which is COMMAND.COM checking for Ctrl-C between
two batch commands -- so the photograph was of the batch file's own screen
rather than of the program the script was written to watch.

#### Three things that will bite

* **Keys leak into COMMAND.COM.** Between two commands in a batch it polls
  the keyboard, and a key that has come due is handed over and executed as a
  command. Start every script with a `PAUSE` long enough to cover the gap,
  and load the TSR in the same job as the target, immediately before it.
* **A target that asks for more keys than the script holds will block the
  box.** Once the script is exhausted the handler chains to the real BIOS,
  which waits on a keyboard nobody is at -- and nothing polls while it does,
  so that is a needs-hands hang rather than a job timeout. End scripts with
  more keys than the program can possibly want.
* **Redirection can switch the prompt off entirely.** `MEM /P > NUL` does not
  page, so it never asks for a key and the script does nothing: measured, 0
  keys sent and 0 snapshots. A program that only prompts when writing to a
  console is not being tested at all when its output is redirected.

#### Driving a full-screen editor: typing yes, menus no

Tried on 2026-09-05 against `EDIT.COM`, and the result splits cleanly.

**Typing works completely.** A 372-word script typed a whole short story into
MS-DOS EDIT -- **343 keystrokes, every one of them landed** -- and the file
was saved and read back off the disk afterwards. Escape dismissed the welcome
dialog and `Alt-F` opened the File menu, so INT 16h is being served properly
and even Alt-combinations arrive.

**Menu navigation does not.** Once the File menu is open, neither the
accelerator (`x` for Exit, either case) nor Down-arrow-then-Enter has any
effect: the menu just sits there highlighted on "New". Whatever EDIT reads
its menus with, it is not the INT 16h path this TSR hooks. One run did exit
cleanly on that same sequence, which was never reproduced -- treat it as
unexplained rather than as evidence the keys sometimes work.

So: KINJ can fill a text field or answer a prompt. It cannot navigate a
full-screen application's menus, and a script that assumes it can will strand
itself -- which is the far more serious problem:

#### A STRANDED script is worse than an exhausted one

The note above says an exhausted script blocks the box. A script that stops
*part way* is worse, because it outlives the job that loaded it.

`/S` says `script finished` when the script ran to `END`. When it does not,
the TSR stays resident **with keys still pending**, and COMMAND.COM polls the
keyboard between every pair of batch commands -- including the agent loop's.
Observed: `343 key(s) sent` with no `script finished`, the job timed out, and
then **`AI.BAT` itself froze** and never picked up another job. It took
Ctrl-C and answering `N` at the keyboard to free it.

That is a hazard with a delay fuse: the job that created it has already gone,
and the machine stops polling some time later for no visible reason. Three
rules follow:

* **`KINJ /U` belongs in the same job as the target** -- and on a line the
  job will actually reach. Putting it after the target is not enough if the
  target can hang.
* **Prefer a target that cannot outlast the script**, the way every `CHOICE`
  in the demo carries `/T`. A timeout makes a missed key cost a default
  instead of the box.
* **Check `/S` for `script finished`.** It is the difference between a TSR
  that is done and one that is still holding keys for whoever asks next.

#### What it cannot drive

**Anything that hooks INT 9 and reads key state itself never calls INT 16h**,
so it never sees any of this. That is most games, and it is `RAYCAST KEYS`.
Reaching those means the keyboard controller: 8042 command **D2h**, "write to
output buffer", presents a byte as though the keyboard had sent it and raises
IRQ1, so the real INT 9 chain runs on a scancode of your choosing. This box
has a genuine 8042 -- `SCRLOFF.COM` already drives it through ports 60h/64h
-- so it should work here. **Untried**, and not every clone implements D2h.

Buffer stuffing -- scancode/ASCII pairs into 0040:001E, tail advanced at
0040:001C -- still works and needs no resident code, but it holds 15 entries
and can only ever *pre-load* a program's input, never steer it while it runs.
`STUFFQ.COM` did exactly that when ScrollLock was being chosen over a
keypress.

#### A live remote keyboard: `KNET.COM`

**Built and verified on hardware 2026-09-05.** `starter/knet.asm` (2276
bytes) with `starter/sendkeys.py` on the Windows side. **`knet.md` is the
full write-up** -- setup, the three-window pattern, the wire format and
troubleshooting; what follows is the part worth knowing without going there. Where `KINJ` replays a
script loaded up front, this delivers keys **as you press them**, into a
program that is already running.

```
KNET /T          listen and report, NEVER resident   <-- always start here
KNET [port]      go resident (default UDP 8071)
KNET /S          resident? counters
KNET /U          release the handle, unhook, unload
```

The proof is an exit code again: `CHOICE /C:AB` was left waiting on the box,
`B` was typed on Windows, and `CHOICE` echoed `B` and returned **errorlevel
2**. Paired with `doscap live` this is real remote control -- see the screen,
type into it.

#### The packet driver is the only way in

DOS is single-tasking and not reentrant, so while the target runs nothing
else does and an interrupt handler cannot call DOS to read a socket -- which
is exactly why `KINJ` has to load its whole script before the target starts.
The one exception is the **packet driver**: it is callable at interrupt time
and needs no DOS at all. It calls our receiver for every matching frame, and
that receiver queues a keystroke touching nothing but our own memory. INT 16h
then hands the queue out.

#### Plain UDP, not a private ethertype

A private ethertype (88B5, say) would leave IP untouched, but sending raw
layer-2 frames from Windows means installing a capture driver. Ordinary UDP
needs nothing at all, at the price of parsing IP and UDP headers by hand in
assembler and of **holding ethertype 0800**, which takes IP away from
`UGET`/`UPUT`.

That sounds fatal and mostly is not: while the target is running the agent
loop is **blocked running it**, so nothing else wants IP during a session.
The handle is held for the session and released before the job ends.

**The trap is loading KNET as the last thing a job does**, which is the
obvious way to try typing interactively. The handle is still held when the job
ends, so `UGET` cannot get one and the box cannot poll:

```
UGET: access_type refused for ethertype 0800, driver error 10
```

Healthy machine, completely unreachable. Load KNET **and the target in the
same job**, so the job is still running while you type and reaches `/U` when
the target exits.

**And it un-strands itself.** Relying on `/U` being reached is not good
enough, so after 120 idle seconds (`/W<secs>`; the timer resets on every key)
KNET gives the handle back by itself. Verified by causing the fault
deliberately and then leaving it alone: **recovered on its own in ~6
seconds**, no hands.

It releases but deliberately does **not** unhook: restoring the vector needs
`INT 21h` and the watchdog can run from inside DOS -- COMMAND.COM polls the
keyboard from its break check, itself inside an `INT 21h`. The packet-driver
release touches no DOS, so that half is safe and is the half that matters.
~2 KB stays allocated until `/U` or a reboot; a small leak beats a trip to
the machine.

#### Keystrokes MUST be broadcast

Not a convenience -- measured, in a single 15-second run:

| | frames reaching our port |
|---|---|
| unicast to the box | **0** |
| broadcast | **23**, carrying 92 keys |

**Nothing on the box answers ARP while KNET holds the IP handle.** By then
the 0806 handle is long released, so Windows cannot revalidate its cache and
quietly stops delivering unicast -- the same mechanism the poll-hold section
above documents, seen from the other side.

Broadcast needs no resolution at all, which also means this TSR needs **no
gratuitous-ARP emitter**: a whole block of interrupt-time code that would
otherwise have to exist and be correct. The cost is that every host on the
segment sees the keystrokes. On a lab network that is a fair trade; do not
type a password through it.

#### `/T` exists because the failure mode is a dead network

`access_type` hands the driver a **far pointer into our code** which it calls
at interrupt time. Exit without `release_type` and that pointer dangles into
memory DOS reuses, the next matching frame jumps into it, and the bridge runs
over that network.

So `/T` acquires, listens, reports and releases in **one run, never going
resident**. It also counts frames at each stage of the parse -- ethertype,
protocol, port, magic -- which is what turned "0 keys, no idea why" into "23
frames reach the port on broadcast and 0 on unicast" in a single run. Build
the instrument before trusting the null result; this file has had to relearn
that repeatedly.

Two orderings are load-bearing:

* **Hook INT 16h only after `access_type` succeeds.** Otherwise a refused
  handle leaves us resident, hooked and useless -- and unhooking is the part
  that needs us to still be there.
* **On unload: release, then unhook, then free.** Free first and the driver
  is left calling into a block DOS has already handed to the next program.

#### What it still cannot do

It serves **INT 16h**, so it inherits `KINJ`'s exact blind spot: a program
that reads the keyboard at INT 9 never sees any of it. That includes
`EDIT.COM`'s menus -- typing into the editor works and the menus do not, and
a live keyboard does not change that, because the limitation is in what the
target reads rather than in how the keys arrive. Reaching those still means
8042 command **D2h**, still untried.

Note also that `KNET` chains when its queue is empty, so the real keyboard
keeps working throughout and somebody standing at the machine can always take
over.

### Mouse injection: easier, and a different shape entirely

There is no queue to stuff. INT 33h is a **driver call interface**, so
faking it means hooking INT 33h and answering the functions an application
asks -- 03h (position and buttons), 0Bh (motion counters), 05h/06h (press
and release counts) -- chaining everything else. That is simpler than the
keyboard TSR, not harder: no ISR, no hardware port, no timing.

Two things worth knowing before trying it. **Moving the pointer needs no
hook at all** -- INT 33h function 04h sets the cursor position and any
ordinary program can call it; only the BUTTONS need interception. And an
application that installed an event handler with function 0Ch expects
callbacks, so a complete fake has to call that handler itself rather than
just answering polls.

On this box `CTMOUSE` owns COM1 in Mouse Systems mode -- and only after
`CTMOUSE /S1 /M /3`, since `AUTOEXEC.BAT` still carries the line that probes
wrong. A hook would sit above it and would not care.

### Where the drawing goes, and why it is a hard floor rather than a soft one

With casting in assembler, drawing is three quarters of the frame. `NOWALL`
and `NOBAND` split it -- both skip work while leaving everything else intact,
including the dirty-band bookkeeping, so the pieces add up:

| | ms | share |
|---|---|---|
| wall columns | **51.0** | 53% |
| ceiling and floor bands | 17.7 | 18% |
| cast, the column loop and the flip | 27.2 | 28% |

**The wall blitter is running at essentially 100% bus utilisation, and that
is measurable rather than asserted.** Counting which sampling path draws each
row:

| path | rows | share | bytes/pixel |
|---|---|---|---|
| one lookup per 4 rows | 238800 | 23% | 6.5 |
| one lookup per 2 rows | 515832 | 49% | 8.0 |
| a lookup every row | 298969 | 28% | 11.0 |

That weights to **9.1 bytes of instruction fetch plus 2 data accesses per
pixel**. The measured cost is 51.0 ms for 10229 wall bytes a frame, which is
4.99 us a byte -- divide by 11.1 bus accesses and it comes to **about 3.6
clocks each**, against the 8086's four-clock bus cycle.

So there is no slack left to find: the loop is not waiting on anything except
memory, and the only thing that would make it faster is fewer bytes. Every
instruction in it is already the shortest encoding that does the job, which is
why `XLAT` and the DS/ES choice mattered and why unrolling further does not
-- the extra stores need disp16 and give the saving straight back.

#### Why the overdraw stays, with the arithmetic

The bands paint the whole dirty band and the walls then cover about 10229
bytes of it, so roughly 43% of all writes are painted twice. Removing that
looks obviously right and is **wrong**, because the two writes are not the
same price:

| | us/byte |
|---|---|
| band, full-width contiguous `REP STOSW` | 1.23 |
| wall, strided and textured | 4.99 |
| a strided, row-shaded fill (what exact painting needs) | ~8.2 |

| | |
|---|---|
| today: 12600 bytes contiguous | **15.5 ms** |
| exact: 2371 bytes strided and shaded | 19.5 ms |

Painting five times the bytes in one unbroken `REP STOSW` beats painting the
minimum in a strided loop. The contiguous fill is 6.7x cheaper per byte, and
that ratio is bigger than the 5.3x saving in area.

#### What did move: runs of equal shade in the band

`RowShade` has 16 levels over 100 rows, so about six consecutive rows share a
colour -- and rows are 80 bytes with an 80-byte stride, so those six are one
unbroken block. Restarting `REP STOSW` per row cost about 21 us a row in
setup for nothing. Emitting one per RUN instead took the bands from 17.7 ms
to 15.5 ms.

`NOWALL` and `NOBAND` are kept as arguments. They render nonsense on purpose
and exist to be timed against.

### Casting in assembler: 22.0 -> 44.7 fps, and the 8087 stops being worth it

The drawing had been assembler for a while; `CastColumn` was still Pascal,
and at ~38 ms of a 110 ms frame it was the last big block of it. Converting
it in four stages, each measured:

| | cast | frame |
|---|---|---|
| Pascal, after the five wins below | 26.4 | 9.1 |
| texture setup in asm | 28.8 | 9.3 |
| DDA in asm | 32.0 | 9.6 |
| head merged into the same block | 34.7 | 9.9 |
| tail in asm (fisheye, divide, extents) | 38.8 | 10.1 |
| ...and the divide made 16-bit | **44.7** | **10.5** |

`FLAT` went **12.1 -> 16.3 fps** over the same work.

**Nothing in there is clever, and that is the point.** The gain is almost
entirely that Pascal keeps every local in BP-relative memory, so each step
stores its result and the next one loads it back. In assembler the two side
distances stay in AX and BX and the grid index in SI for the whole walk.
Merging the angle lookup, both initial side distances and the DDA into ONE
block was worth another 8% on its own, purely from not round-tripping
between them.

#### The perspective divide was 32-bit for no reason

The integer path read `Integer((LongInt(SCR_H) * ONE) div Perp)`, and FPC
calls a software routine for that -- `BENCH` puts a 32-bit divide at
7280/sec, **137 us**. But the numerator is `200 * 256 = 51200`, which fits
in a word, and `Perp` is clamped to at least `PERP_MIN`, so the quotient
cannot overflow. A plain 16-bit `DIV` does it in about 90 cycles.

**That reverses the guidance elsewhere in this file about the 8087.** The
earlier measurement was honest and is still correct as far as it went: the
coprocessor beat a *32-bit software divide* comfortably. It does not beat a
*16-bit hardware divide* -- FILD, FDIVR, FISTP and FWAIT go through memory
in both directions and cost roughly 300 cycles against 90.

| | cast | frame |
|---|---|---|
| `FPU` -- 8087 | 38.8 | 10.1 |
| `INT` -- 16-bit DIV | **43.6** | **10.5** |

So the integer path is now the default and `FPU` is kept for the
comparison. The general lesson is the one this file keeps relearning: **a
measurement is only valid against the alternative it was measured against.**
Nothing about the 8087 changed; the thing it was being compared with got 15
times faster, and the conclusion inverted.

This matters well beyond this box, too. Most 8086-class machines have no
coprocessor at all and were taking the integer branch -- so they were paying
137 us a column for a divide that never needed 32 bits.

#### Two traps in converting Pascal to asm here

* **IMUL owns DX**, so anything already in it is gone. In the merged block
  `SdX` is pushed on the stack across the second multiply because there is
  no spare register; the push/pop nests inside the SI/DI pair so the block
  stays balanced on every path.
* **FPC addresses locals and parameters through BP.** Every one of these
  blocks preserves SI and DI explicitly and never touches BP -- the one time
  that rule was broken, in the first texture blitter, it wedged the machine
  and needed a power cycle.

### Five optimisations that did land, 8.2 -> 9.1 fps

Run after the floor measurement below, which is why each one is small: the
easy factors were already gone. Every number is measured on the V30.

| | | cast | frame |
|---|---|---|---|
| | starting point | 22.0 | 8.2 |
| A | `-O2` into a **private unit directory** | 23.7 | 8.5 |
| B | video in DS, texture in ES | -- | 8.6 |
| C+D | no DDA bounds check; branchless texture flip | 25.4 | 8.8 |
| E | pivot cache | -- | **9.1** |

`FLAT` came along for the ride: **12.1 -> 13.5 fps**, and its cast went 28.6
-> 35.7. Texture setup in the cast is now 9.9 ms a frame.

**A. `-O2` is safe once the units are not shared.** The long-standing
objection was real -- `build/` is one unit directory, so optimised `vga`,
`cpu` and `net` `.ppu` files would be what `UGET`, `UPUT` and `TFTP` link
next, and a miscompile in those is the failure this project designs against.
Pointing one target at its own `-FU` directory removes the coupling instead
of the gain. `build.cmd` now does that for any target with a `<name>.o2` file
beside it; `raycast.o2` explains itself. Nothing else in `starter/` changes,
and deleting the file puts it back on the shared unoptimised units.

**B. Which segment register holds what is worth 1%.** A segment override is
one byte, and on an 8086 a byte of instruction fetch is a bus cycle, so the
question is only which operand appears more often. In the four-rows-a-texel
path there are four stores and ONE lookup -- so video goes in DS (stores lose
their prefix) and the texture in ES (`xlat es:[bx]` pays it once). 29 bytes
per four pixels down to 26. Note `mov [di],al` is DS:[DI]; only the string
instructions default to ES. FPC accepts `xlat es:[bx]` and rejects `es xlat`.

**C. The DDA bounds checks were dead weight, and took `MX`/`MY` with them.**
Every edge cell of `MAP` is a wall, so a ray always terminates on `Cell <> 0`
and the two range tests can never fire. `MX`/`MY` existed only to feed them,
so dropping the tests drops two increments per DDA step as well. `Guard`
still bounds the loop at 64 steps, which is what makes it safe rather than
merely likely -- and nothing in there writes through `Idx`.

**D. `255 - U` and `U xor 255` are the same thing for a byte.** Whether a
face is mirrored depends only on which way the ray steps, so it is a property
of the angle: hold it as a per-angle MASK rather than a flag and the flip is
an XOR with no branch, folded into the same `if Side` that already picks the
direction table.

**E. The pivot cache: +3.4%, and the estimate was twice the truth.** It was
later suspected of rendering wrong geometry and measured as not doing so --
read the section below before suspecting it again. The walk turns on the spot, so on
those frames the camera's POSITION is unchanged and a cast result is still
valid for the absolute angle it was taken at. Ray X's angle is
`Ang + (X - NRays/2)*RayStep`, so turning by `K*RayStep` makes ray X equal to
old ray `X+K` -- the frame becomes a shift of six column arrays plus `|K|`
newly exposed columns.

That is why `FOV` went from 170 to 160: the mapping is exact only when
`RayStep` is a whole number of angle units, and `Advance` snaps the turn to a
multiple of it. Snapping discards at most one ray of turn per frame, under
half a degree. `Move` is `memmove`, so the overlap is safe either way.

**Predicted 8%, measured 3.4%** -- because pivots turned out to be about 17%
of frames rather than the 40% the estimate assumed. The counter is in the
report (`columns cast : 7904, 816 reused`) precisely so the assumption is
visible rather than inferred.

### Where the textured frame's floor is, and four things that did not move it

Measured on the V30, and this is the point to start from before optimising
anything here again:

| | |
|---|---|
| casting, `FLAT` (`NODRAW`) | 28.6 fps -> ~35 ms |
| casting, `TEX` (`NODRAW`) | 22.0 fps -> ~45 ms |
| whole textured frame | 8.2 fps -> ~122 ms |
| therefore drawing | ~77 ms |

So texture setup in the cast costs **10.5 ms a frame, 131 us a column**, and
drawing is roughly 60% of the frame.

**Four attempts to reduce that measured as nothing at all**, and they are
worth recording because each looked obviously right:

* **Folding the bank index and the texture column into one offset.** Removes
  an array store from the cast and three array reads plus an add from every
  column of the draw loop. Result: **22.0 -> 21.7 fps**, slightly *worse* --
  because `bank * BANKSZ` where BANKSZ is 4160 is a real 16-bit multiply, ~17
  us, which costs more than the store it replaced. Tabling the bank offsets
  put it back to 22.0 and **exactly** 8.2 fps on the frame. Kept only because
  one array and one heap block are simpler than two and eight, not because it
  is faster.
* **`-O2`.** +7% on the cast, +4% on the frame, declined -- the gain is in the
  shared units and `build/` is one unit directory, so it would follow into
  `UGET`/`UPUT`/`TFTP`. See the section below.
* **A smaller memory model.** `-WmSmall` is 28% less code and measures
  identically.
* **A full-assembler draw loop** replacing the 80 per-column calls. Measured
  before writing it, by adding a second blitter call per column with `Rows=0`
  so it returns immediately: **8.2 -> 8.0 fps, so 38 us a call and 3.05 ms a
  frame -- 2.5%.** Not worth an asm rewrite of the whole loop, and knowing
  that cost 40 seconds instead of an afternoon.

The lesson that keeps repeating: **`BENCH`'s per-operation figures do not
predict the marginal cost of an operation inside this code.** Four times now,
removing something `BENCH` prices at 15 us has changed nothing. Measure the
specific change, by adding the work if that is easier than removing it.

**What is actually left**, in case someone wants it later: not re-casting
during a pivot. The camera does not move while it turns on the spot, so a
cast result is still valid for a given absolute ray angle; with `FOV` made
divisible by `NRays` a rotation of one ray-step would shift the column arrays
instead of re-casting them. Estimated at about 8% of the frame, and it needs
an FOV change, angle snapping and a `REP MOVSW` of six arrays. Not obviously
worth it, and unmeasured -- which after the four results above is exactly the
reason not to trust the estimate.

### Distance fog, and why the floor is not textured

Fog costs **0.2 fps of 8.4** and is the largest visual improvement left. It
works because nothing about it happens per pixel:

* **Walls** select one of 8 pre-baked banks -- 2 wall types x 4 distance
  bands -- so the blitter reads a different bank and does no shading
  arithmetic at all. The wall's facing folds in as one extra step of
  darkening, so a far wall and a side-on near wall can land on the same bank.
* **Floor and ceiling** take a colour per ROW from a table. A row below the
  horizon is a constant distance from the camera, so `RowShade` depends only
  on the geometry and is built once. Rows are 80 bytes and the stride is 80,
  so `REP STOSW` walks straight through the band and never restarts; the
  only per-row cost is a table lookup and a fresh CX.

One call does each whole band, because 200 Pascal calls a frame at ~30 us
each would cost more than the gradient does.

**The banks moved to the heap.** Eight of them is 33 KB and the data segment
already holds ~40 KB of tables. The blitter has always taken a segment and an
offset rather than a Pascal pointer, so `GetMem` costs nothing here and takes
the 64 KB ceiling off the bank count entirely -- with 540 KB free there is
room for many more.

Two details that are easy to get backwards:

* **Scale both ends of each ramp, not just the top.** Fading only the
  highlights makes a distant wall look washed out rather than dim; the
  mortar has to stay dark at every distance.
* **Compares, not `Perp shr 9`, to pick the band.** A shift by CL is about
  44 cycles on an 8086, and across 80 columns that is more than the whole
  gradient is worth. Three compares cost a handful.

#### Textured floors and ceilings are NOT affordable, and here is the sum

This is the obvious next step and it does not work on this class of machine.
A floor needs a **2D** texture coordinate, so the inner loop carries two
accumulators and builds the index out of both high bytes:

```
mov bh,dh / mov bl,ch / mov al,es:[bx] / mov ds:[di],al
inc di / add dx,ustep / add cx,vstep / cmp di,end / jne
```

That is about **24 bytes a pixel against 7.25 for a wall**, over roughly
twice as many pixels (16000 of floor and ceiling against 8000 of wall). Call
it six times the current wall drawing -- around 400 ms a frame, so about 2
fps. Which is why Wolfenstein 3D shipped flat floors on a 286 and only Doom,
on a 386, textured them.

#### The thumbnail broke, and it broke in the documented way

Once the bands became 16-level gradients, all three surfaces had brightness
ramps, and mapping them all by brightness put walls, floor and ceiling on the
same ASCII characters. The picture came back as a field of noise with no
readable geometry -- **exactly** the failure `SCROLLER.md` describes.

The fix is the rule that section already states: rank by **depth order
first**, then by gradient within each surface. Ceiling gets ramp slots 0-1,
floor 2-3, walls 4-9. The fog is then visible in the thumbnail itself -- a
near wall reads `#`/`%` and a distant one `+`/`*`, which is how the whole
feature was verified over the bridge in the first place.

### Textured walls, and why XLAT is the instruction that matters

`RAYCAST` draws textured walls by default; `FLAT` gets the old solid
colours back for comparison. Four 64x64 banks -- two wall types, each baked
lit and shaded -- generated procedurally at startup so there is no art to
ship. Measured on the V30 over the same 30-second tour:

| | fps |
|---|---|
| `FLAT` | 12.1 |
| textured, first working version | 6.7 |
| textured, tuned | 8.4 |
| **textured + distance fog** | **8.2** |

**The texture is stored COLUMN-MAJOR, and that is the whole design.** A wall
slice reads one texture *column* top to bottom, so transposing the data makes
those 64 texels contiguous; the inner loop then reaches any of them with a
single byte index. Row-major would need a multiply or a 64-byte stride per
texel, in the hottest loop in the program.

#### On an 8086 the figure to shrink is BYTES per pixel, not instructions

The bus is the limit and **instruction fetch competes with data** for it, so a
shorter encoding is faster even at equal instruction count. That is what makes
`XLAT` the right instruction here: it is **one byte** for the whole table
lookup, against four for a `mov` with a base+index operand.

| | fps | |
|---|---|---|
| `mov bl,dh` / `and bl,63` / `mov al,[bx+si]` | 6.7 | 4 bytes for the fetch |
| `mov al,dh` / `xlat` | 7.4 | **1 byte**, +10% |
| ...unrolled to four, row stride in the store displacement | 7.8 | +5% |
| ...sampling the texture less often on near walls | **8.4** | +8% |

#### Sample the texture as often as the wall is magnified, not once a row

A slice stretches `TEXH` texels over however many rows it covers, so a near
wall already shows each texel several rows deep and sampling per row is
repeated work. `VStep` is texels-per-row in Q8, so it states the
magnification directly and the blitter picks a rate from it:

| `VStep` | | sampling | bytes/pixel |
|---|---|---|---|
| <= 64 | 4+ rows a texel | one lookup per **4** rows | 7.25 |
| <= 128 | 2+ rows a texel | one lookup per **2** rows | 8.5 |
| else | | every row | 11.5 |

The stores cannot go -- one byte a row, 80 apart -- but the `XLAT` and the
accumulate can be shared, and those are three fetched bytes each. All three
paths share one remainder loop so each can assume a multiple of four.

Sampling at the top of a group rather than the middle can put a texel
boundary one row early. At 2x magnification or more that is invisible, and
it is close to what nearest-neighbour produced anyway.

**The stores are now most of what is left.** Per four pixels the bulk loop is
17 bytes of stores against 3 for the lookup, and the alternatives measure no
better: stepping `DI` between stores costs more than the disp16 on the third
and fourth, and `XLAT`'s one-byte encoding only works against `DS`, so the
video segment has to be the one carrying the override.

The texel index is deliberately **not masked**. The arithmetic lands on
exactly 64 at the bottom row of an unclipped slice, so the worst case reads
the next column's first texel into the last row -- one pixel, invisible --
and each bank is padded by `TEXH` so even the last column stays in bounds.
Masking cost 4 cycles and 3 bytes on every pixel to prevent that.

#### Two things that are NOT divides

* **The texel step needs no divide.** `VStep` is `TEXH*256/Hgt`, and `Hgt` is
  `SCR_H*ONE/Perp`, so the two cancel: `VStep = Perp * 0.32`, one multiply.
  A second divide per column would have cost more than the whole blitter
  tuning bought back.
* **The texture coordinate needs the PRE-fisheye distance.** `Pos + RayD*Dir`
  is the hit point only while `Dir` is a unit vector and `RayD` is measured
  along the ray. Using the corrected distance bends the texture towards the
  edges of the screen.

#### What it costs, and where

| | flat | textured |
|---|---|---|
| casting | ~34 ms | ~44 ms |
| drawing | ~47 ms | ~84 ms |

Casting grew because the cast now writes four more arrays per column, and
`BENCH` puts an array store at 14.6 us -- four of them across 80 columns is
~4.7 ms before any arithmetic. Drawing grew because **run coalescing is gone
and cannot come back**: adjacent columns sample different texture columns, so
every run is one ray wide by definition. That is why the coalescing is still
there on the `FLAT` path and why the two paths are kept side by side.

#### The bug that wedged the machine

The first version hung the box hard enough to need a power cycle. **FPC
addresses procedure parameters through BP**, and the blitter loaded `VStep`
into BP before it had read `TOfs` and `TSeg` -- so those two came from
whatever the stack happened to hold. Nothing warns. Every parameter is now
read before BP is touched, and the comment there says so.

Worth pairing with the other trap from the same session: **`InC` IS `Inc`.**
A loop variable named `InC` shadows the built-in, and `Inc(L, 2)` two lines
later stops compiling. That one failed loudly; the BP one did not. Pascal
being case-insensitive has now cost two names in one file -- see also
`DdX`/`DDX` below.

#### EMS would not help, and neither would a smaller memory model

Both were asked and both were measured or reasoned to nothing:

* **EMS.** The whole texture bank is 8 KB against 540 KB free, so there is
  nothing to page out. EMS is a capacity mechanism: data sits behind a 16 KB
  window and anything outside the mapped page needs an `INT 67h` remap
  costing hundreds of cycles. The texture fetch is the innermost instruction
  in the frame.

  A **Lo-tech 2 MB ISA card** was fitted on 2026-09-04 and works -- `MEM`
  reports 2,048 KB total and free, at a cost of 5 KB of conventional memory
  for the driver. It changes nothing about the frame rate and was not
  expected to. Where it *would* earn its keep is content: many more wall
  types, plus floor, ceiling and sprite art, paged at **wall-type
  granularity** -- a handful of `INT 67h` switches a frame rather than one
  per pixel, which is affordable. Capacity, not speed.
* **The memory model.** `-WmSmall` is 28% less code than `-WmLarge` (44346
  against 31697 bytes) and measured **identically** -- 29.6 against 29.8 fps
  on the cast, 12.3 both on the frame. FPC keeps `DS` on the data segment
  either way, so "far data" costs nothing for direct global access.

### The cast loop: a far call cost 29.5 us, and there were four a column

With drawing halved by the page-flip work above, casting became the bigger
half of the frame and the question was what it actually spends its time on.
80 rays at ~2.8 DDA steps each is not much arithmetic, so the ~485 us a ray
had to be going somewhere else.

**The measurement that answered it was a deliberately wasteful one.** Rather
than reason about the cost of a call, add one: a fourth `MulQ8` per column,
its result parked in a global so nothing optimises it away.

| | cast fps |
|---|---|
| as it was | 27.7 |
| with one extra call a column | 26.0 |

2.36 ms a frame across 80 columns, so **29.5 us for a single call** -- more
than BENCH's 21.5 us for a bare procedure call, which is what a far call in
the large model with two parameters and a return value costs.

There were four such calls per column: two for the initial side distances,
one for the fisheye correction, one for the perspective divide. Writing all
four out where they are used:

| | cast | frame |
|---|---|---|
| calls | 25.8 fps | 11.5 fps |
| written out | **29.4 fps** | **12.3 fps** |

14% off casting, 7% off the frame, and **no compiler flag involved**. Note the
saving is about half what 4 x 2.36 ms predicts: staging operands into locals
for the `asm` block gives some of it back. Predicted savings from a per-call
cost are an upper bound, not an estimate.

**FPC will not inline an assembler routine, and it tells you so.** Marking
`MulQ8` as `inline` produces `Call to subroutine ... marked as inline is not
inlined` and byte-identical output. Believe the note.

#### Two traps in writing it, one of which cannot bite twice

* **A local called `DX` is unreachable from an `asm` block.** The assembler
  resolves the name as the register, and nothing warns. The locals here are
  `RdX`/`RdY` for that reason.
* **Pascal is case-insensitive, so `DdX` *is* `DDX`.** The obvious rename
  collided with the `DDX`/`DDY` reciprocal tables and shadowed them into a
  plain Integer. That one failed loudly -- `Illegal qualifier` on `DDX[RA]`
  -- but only because the shadowed thing was indexed. A shadowed scalar would
  have compiled and quietly read the wrong variable.

#### Two changes that measured as nothing

Recorded because both looked obviously right:

* **`Inc(Idx, SY * MAPW)` is not a multiply.** It reads like one in the
  hottest loop in the program, and hoisting it into a per-angle table changed
  the frame rate by nothing at all. `MAPW` is 16, so the compiler had always
  been emitting a shift. Reverted. Check the constant before optimising the
  operator.
* **`-O2` is real but was declined.** Measured: +7% on casting, +4% on the
  frame; `-O3` was no better and produced a bigger binary. `build.cmd` passes
  no `-O` at all, so everything in `starter/` is unoptimised.

  It was not adopted because **the gain is in the shared units, not in
  `raycast.pas`** -- pinning it to the one file with `{$OPTIMIZATION LEVEL2}`
  measured identically to no directive. Optimising the units means `vga`,
  `cpu`, `about` and eventually `net` compile through an optimiser none of
  them has been through, and `build/` is one shared unit directory, so those
  `.ppu` files are what `UGET`, `UPUT` and `TFTP` would link next. Those are
  the programs the box needs in order to be reachable at all; they are I/O
  bound, so there is nothing there to win, and a miscompile in one of them is
  the failure this project designs against. 4% of a demo's frame is not worth
  buying with that.

  Worth knowing separately: **`{$OPTIMIZATION LEVEL2}` placed after the
  `program` header does nothing and says nothing.** Byte-identical output. It
  is a global switch and has to precede the header -- and even correctly
  placed it only covers that one file, which is what the measurement showed.

### Mode X: the earlier step, and two orderings that bit twice

`RAYCAST MODEX` unchains the display. With the map mask at `$0F` one byte
write paints four horizontal pixels, so the full-screen band clear -- measured
as the floor of the mode 13h version at 78 ms -- becomes 16000 writes instead
of 64000, and a four-pixel wall column is one byte a row instead of four.

Measured on the V30:

| | |
|---|---|
| default, 160 rays, mode 13h | 4.1 fps |
| `BLOCKY`, 80 rays, mode 13h | 5.5 fps |
| **`MODEX`, 80 rays, unchained** | **8.6 fps** |

2.1x, not the 3x the write count suggests -- the per-byte cost does not vanish
just because each byte covers more pixels, and casting is untouched at ~40 ms.

The four registers are set in `raycast.pas` rather than reusing `modex.pas`,
which hardwires the scroller's 1024-pixel virtual screen. Parameterising that
unit would put its verified 70 fps at the mercy of edits made for a demo
running at eight. `XEnter` reads all four back: a card that ignores one leaves
a picture that is *skewed* rather than absent.

**`VSHOT` cannot photograph an unchained mode**, so the ASCII thumbnail reads
back through Read Map Select -- `XPeek` picks the plane with `X and 3`. Without
that there would be no way to tell a working renderer from a broken one over
the bridge, which is the whole reason the thumbnail exists.

**The same ordering mistake was made twice, and is worth naming.** Both times
a value was consumed before the thing that decides it had run:

* The header printed `video : mode 13h -- unchain refused at check 0` with all
  four readbacks reading zero. `XEnter` had not run yet: the banner is printed
  before the mode is chosen. The report belongs with the results, not the
  header -- it is an outcome, not a setting.
* `NRays` was forced to 80 inside `BuildColumns`, gated on `UseX`. But
  `BuildColumns` runs long before the card is asked to unchain, so the guard
  read a `UseX` that was still False and the demo drew two-pixel columns
  through a four-pixel blitter. Now forced where the argument is parsed.

Both printed or produced something plausible rather than failing, which is why
neither was obvious. If a flag is set by a probe, check what has already
consumed it.

**There is no `Has186` fast path in it, and that is a consequence rather than
an oversight.** The extension that would matter is the shift by an immediate
count, worth about 11% by `BENCH` (206260 against 185021) -- on an operation
this program deliberately never performs. Q8 scaling is a byte shuffle, screen
offsets are computed once per rectangle rather than per pixel, and the fill is
a string instruction. Designing the 32-bit arithmetic out took the 186 case out
with it. `CpuName` is still reported, because knowing what it ran on is the
point.

### What the music actually costs, and the PC speaker

The AdLib is the obvious suspect when a demo is choppy, and on this one it is
innocent. Measured on hardware, same maze, same 30 seconds:

| | fps |
|---|---|
| `QUIET` -- no music at all | 11.2 |
| AdLib playing | **11.1** |

**0.1 fps, under 1%.** A note event is about 0.8 ms of register writes and
there are only a couple a second against an 83 ms frame.

The intuition that it must be expensive is right about the mechanism and right
about the *scroller*, where the notes below record music costing a whole
sprite. The difference is the frame budget: at 70 fps a frame is 14.27 ms, so
0.8 ms is 5.6% of it **and** going over pushes the frame across a retrace
boundary, where the cost is not 6% but half the frame rate. The raycaster
waits for no retrace and has an 83 ms frame, so the same absolute cost is six
times smaller in relative terms and has no cliff to fall off. **Ask what
fraction of the frame it is, and whether anything quantises the frame.**

Also worth knowing before reaching for one: **a Sound Blaster would not help.**
Its FM synthesis *is* an OPL2/OPL3 at the same ports 388h/389h, so it is the
same cost to the byte. Only its DMA digital audio is cheap, and that needs
sample data and a DSP.

`RAYCAST SPKR` plays through the PC speaker instead, and that is the automatic
fallback when no OPL2 answers -- which matters because most 8086-class
machines have none and were getting silence. It is about **availability, not
speed**: four OUTs with no mandated delay against nine register writes each
needing a settling wait, roughly a hundred times cheaper per note, and none
of that is worth 0.1 fps.

The catch is real. The speaker is one voice, the theme is three, and the
tritone that makes it sound like a mystery is an interval *between* two of
them -- something a monophonic device cannot state at all. What it plays is a
reduction: the melody where there is one, the chromatic walk where there is
not. Recognisably the same tune, not the same effect.

### Sound while something else is running: `starter/opl2.pas`

`AMOZART` plays a tune and does nothing else, so it can key a note and wait.
Anything with a frame loop cannot, and that is the whole difficulty. The unit
holds the parts that are about the chip rather than the music: `OplDetect`
(the timer method), `OplWrite`, `OplVoice`, `OplNoteOn`/`Off`, `OplSilence`.
`starter/music.pas` is the worked example of driving it from a frame
loop. Note `amozart.pas` predates the unit and still carries its own copy.

Three things learned wiring music into the scroller:

* **Register writes are dear, and it is all waiting.** The chip needs >3.3us
  after an address byte and >23us after data, spent reading the status port.
  `amozart.pas` does that with a Pascal loop, which `BENCH` puts at ~11us an
  iteration, so each register write costs it roughly 480us. Fine for a program
  doing nothing else; far too much inside a frame. The unit uses an assembler
  loop -- same number of bus cycles, about a sixth of the wall clock. Even so,
  three voices changing together is nine writes and about 0.8ms, and that was
  enough to cost the demo a sprite.
* **Take the tempo from the BIOS tick, never from the frame count.** Counting
  frames is the obvious thing when the caller already has a frame loop, and it
  is wrong precisely because of the quantisation above: one sprite more or
  less does not slow the music by 10%, it halves it.
* **Silence the chip on every exit path**, including the error ones. A program
  that quits with a voice still ringing leaves the machine droning, and over
  the bridge nobody can hear that it happened.

`starter/prof.pas` times sections inside a program, so finding a hotspot no
longer means building cut-down copies of it (which is what locating the SVGA
demo's bottleneck actually took).

```pascal
uses Prof;
...
ProfStart;
BuildFrame;   Mark('build');
PaintFrame;   Mark('paint');
ProfReport;
```

Resolution comes from latching PIT channel 0 rather than reading BIOS ticks,
giving ~0.84us instead of 55ms. Reading it needs care: the counter runs down
and wraps slightly before the BIOS ISR bumps the tick, so pairing a post-wrap
counter with a pre-wrap tick makes time run *backwards*. `HiRes` retries until
two tick reads agree, and `Mark` adds one tick back if a delta still comes out
negative.

`ProfReport` also prints a stack watermark, sampled at each `Mark`. That is
there because a recursive directory walker with 12KB frames overflowed the
stack and hung the machine with no diagnostic at all — DOS has no stack guard.

**Give each section at least a few thousand iterations.** Sections of about a
thousand measure roughly 2x slow — `MemW` to B800 read 27763/sec over 1000
writes but 61573/sec over 10000, the latter agreeing with `BENCH`. The cause is
not understood and it is not a fixed overhead (a 4000-iteration section was
accurate to 3%), so treat short sections as unreliable rather than trusting the
absolute number.

`SERIAL` reads the UART registers back rather than assuming anything, so it
shows the baud rate, framing and modem lines a driver has actually configured.
On this machine COM1 (03F8) reads 1200 baud, DTR and RTS asserted, OUT2 set and
the receive interrupt enabled — the exact fingerprint of `CTMOUSE` driving a
serial mouse. DTR/RTS are not incidental there; they are what powers the mouse.

Reading the baud divisor requires setting DLAB in the LCR, which is a write to
a live port, so it is done with interrupts disabled and the LCR restored
immediately. `/T` (UART generation) is opt-in because it writes the scratch and
FIFO registers, and `/M` monitor mode **steals bytes from whatever driver owns
the port** — do not point it at COM1 here while CTMOUSE is loaded.

`MOUSE` deliberately uses INT 33h rather than the UART for that reason: CTMOUSE
owns COM1 and its interrupt. It reports travel and button transitions so the
result is verifiable from the Windows side, but someone has to actually move the
mouse while it samples — run it with `run_in_background` so you can say so
before it finishes. Better still, prefer `SERIAL 1 /ID`, which power-cycles the
mouse via DTR/RTS and reads its reply: silence there is real evidence, whereas
silence from `MOUSE` only means nobody happened to touch it.

### The mouse is a Mouse Systems device, not Microsoft

Worked out on 2026-08-29 by capturing the raw wire. It sends **5-byte packets
with a `1000 0xxx` header** (buttons active-low in bits 2..0, `87` = none down),
where a Microsoft mouse sends 3-byte packets with bit 6 as the sync flag and an
ASCII `M` at power-up. A driver framing for the wrong one sees pure noise.

`AUTOEXEC.BAT` runs `ctmouse /m /3`, and that is **not** enough: `/M` only means
"try old Mouse Systems for non-PnP mice", so CuteMouse's probe still settled on
the wrong protocol and INT 33h reported no movement at all. What works is
forcing the port:

```
CTMOUSE /U
CTMOUSE /S1 /M /3        -> "Installed at COM1 (03F8h/IRQ4) in Mouse Systems mode"
```

After that the mouse reports properly. This is currently a run-time fix only;
`AUTOEXEC.BAT` still has the old line, so it reverts on reboot.

Beware when writing protocol detectors: negative movement deltas (`DD`, `E2`,
`EB`, `F4`, `FC` …) all have bit 6 set. Testing `B and $40` counts movement data
as Microsoft headers and misreports a working Mouse Systems mouse the moment
somebody moves it. Match the whole header shape — `(B and $F8) = $80` for Mouse
Systems, `(B and $C0) = $40` for Microsoft.

`SCRAPE` and `VSHOT` exist to defeat the "direct video writes vanish" rule at
the top of this file. Anything drawing straight to video memory is invisible
over the bridge; these read the buffer back and send it through DOS as ordinary
captured text. Run them in the same job, right after the program:

```
dosexec "MYPROG" "SCRAPE"          text screens
dosexec "GTEST" "VSHOT"            graphics screens
```

Setting a video mode clears video memory, so a program that restores text mode
on exit leaves `VSHOT` nothing to capture. The demos in `starter/` all restore.
`GTEST` deliberately does not, which is what makes it a usable test fixture.
`VSHOT` derives brightness from the DAC rather than the palette index, because
index order says nothing about brightness.

`DSTAT` replaces `DIR /S` piped through a batch file and parsed on Windows:
19 seconds instead of ~5 minutes, and it returns twenty lines rather than
200 KB. It is also *more accurate* than `DIR /S`, which silently skips hidden
directories — on `E:` it finds 3549 files where `DIR /S` reports 3545, the
difference being 4 files inside two hidden `SYSTEM~n` folders. Note `DIR /S`'s
own "Total files listed" counts directories and every `.`/`..` entry as files.

`DEVS NAME` is the reliable answer to "did my driver actually load?" — the
question `##BOOTOK` cannot answer. `MEM /C` only shows drivers that own a
memory block, so it can miss one; this walks the chain DOS really keeps.
Use it after `dosdrv`, and note it only matches *character* devices by name.

`HD` reads binaries that `TYPE` truncates at the first 0x1A. Its CRC-32 matches
Python's `zlib.crc32`, verified on a 25872-byte file, so a deployed file can be
checked against the Windows copy without transferring it.

## Upgrading the DOS box over the wire

Once the bridge is up, the client half updates itself; no USB, no floppy.

```
dosctl upgrade --dry-run      always start here
dosctl upgrade                tools that differ, then the agent, then reboot
```

**Tools** are ordinary `dosdeploy`s into `C:\TOOLS`. One `DIR` listing is
compared against `starter/build` by **file size** and only the differences are
sent — one round trip instead of twenty-five. Size is a proxy for deciding
*what to send*, so `--force` resends everything.

**What arrived is then checked by CRC-32, not by size.** Deployment used to be
confirmed with `IF EXIST` alone, which means a transfer that arrived truncated
to exactly the expected length -- or corrupted without changing length -- would
have reported success. Not hypothetical: when the box went silent after an
upgrade on 2026-09-02, a silently bad `UGET.EXE` was the leading suspect and
there was no way to rule it out from this side. `HD` on the box produces the
same CRC-32 as Python's `zlib.crc32`, so the check needs no new tool:

```
1 tool(s) sent, 0 failed
verified by CRC-32: 1 of 1 match
```

`dosctl verify` runs the same check over **every** tool on demand, which is the
answer to "is the box's toolset actually intact?". It takes a minute -- `HD`
reads every byte on an 8086.

Two details in it are load-bearing. Each check is preceded by an
`ECHO ##F=<name>` marker rather than trusting the `crc32` lines to come back in
request order: a missing file makes `HD` print an error and **no** `crc32` line
at all, which without markers would shift every later result by one and
mis-report every tool after it. And a box with no `HD.EXE` yet reports
"not verified" rather than failing the upgrade -- a fresh install has no tools
to check with.

**The agent loop is the dangerous one, and the ordering is the safety
mechanism.** COMMAND.COM reads a batch file incrementally *by byte offset*,
re-opening it after every line. Overwrite `C:\AI\AI.BAT` while it is running
and control returns to the old offset inside the new file, landing mid-line and
executing whatever text is there — on a machine that no longer has a working
agent to tell you about it. So the swap happens inside `JOB.BAT` and is
followed immediately by `REBOOT.COM`: `AI.BAT` is never read again after it is
overwritten. Same trick the driver path uses to end with `COLDBOOT.COM`.

Three guards run before anything is overwritten:

* **The end marker.** `dosctl` appends `REM ##AGENT-END` as the last line when
  staging, and the DOS side runs `FIND` for it. A truncated download therefore
  cannot become the agent. This costs nothing and needs no CRC.
* **The address check.** `dosctl` pulls the running `AI.BAT` first and compares
  `SET SRV=` / `SET UPHOST=`. The box is reaching you on those values right
  now, so they are the only ones known to work; sending an agent with different
  ones produces a machine that boots, never polls, and needs hands. Refused
  unless `--force`.
* **The rollback.** The outgoing agent is kept as `C:\AI\AI.BAK`.

If it does not come back, at the keyboard: `COPY C:\AI\AI.BAK C:\AI\AI.BAT`.

### "It did not come back" was wrong, twice over

On 2026-09-02 an agent upgrade that **completely succeeded** was reported as a
failure: `dosctl` printed the rollback instructions above and skipped the
version stamp, while the box was sitting there polling happily on the new
agent. Verified afterwards -- the running `AI.BAT` was byte-identical to the
staged one, and the freshly deployed `UGET.EXE` matched Windows exactly
(47158 bytes, CRC-32 `94F4A595` both sides).

Blaming the box for doing exactly what it was told is the failure this project
keeps having to design against, so both causes are worth keeping:

* **The "it is back" threshold was shorter than one poll cycle.**
  `wait_for_box` decided the box had returned when its last poll was under
  **12 seconds** old. A poll that gets no reply costs about 11 seconds and the
  offline branch waits 5 more, so a perfectly healthy box regularly shows an
  age above 12 and the return can be missed entirely between samples. It has
  to be larger than the worst *normal* gap, not smaller. Now 30.
* **The overall limit ignored which polls are least reliable.** It was 240
  seconds, and the polls right after a reboot are the *worst* ones: this
  host's ARP entry for the box has expired by then and our stack does not
  answer ARP, so several cycles fail before one gets through. Measured here:
  over five minutes to land the first poll after a swap. Now 420.

The wording changed too. `##AGENT` has already confirmed the swap by that
point, so the message now says "the swap was confirmed but the box has not
polled yet", tells you to wait a minute and run `dosctl status`, and puts the
rollback last -- and it says outright that the version stamp was skipped, so
`C:\AI\VERSION.TXT` still names the old build until the upgrade is re-run.

**`dosctl reboot` had a second, hand-copied version of that loop** with the
same two thresholds, so the fix would have had to be found twice. It calls
`wait_for_box` now.

### A dropped packet must not silence a safety check

The address check listed above compares the running agent's `SET SRV=` against
the new one, and it does that by **pulling the running `AI.BAT` off the box**.
That pull can fail -- the transport is flaky enough that a single one does now
and then, and one did on the very run that found this. The code then had
`cur_srv = None` and only refused when `cur_srv` was truthy *and* differed, so
an unreadable agent read as **"checked, and fine"**.

That is the worst way for this particular guard to go, because what it prevents
is the one mistake nothing on this side can undo. `dosctl` now treats
"could not read it" as its own outcome and refuses, saying to try again or pass
`--force`.

Worth noting what is still missing: **tool deployment is verified with
`IF EXIST`, not a checksum.** A truncated transfer would report success, and
when the box went quiet the new `UGET.EXE` was the leading suspect for exactly
that reason. `HD` on the box already produces a CRC-32 that matches Python's
`zlib.crc32`, so `dosctl upgrade` has everything it needs to check and simply
does not.

Verified on hardware 2026-08-31: a tool and the agent both went over the wire,
the box rebooted into the new agent and resumed polling, and `AI.BAK` held the
previous one.

### What version is the box on?

`C:\AI\VERSION.TXT` on the DOS machine, three short lines. `AI.BAT` `TYPE`s it
in the boot banner, so the machine answers the question on its own screen
instead of someone having to go and ask the Windows side:

```
DOS Bridge client
build 1+
deployed 2026-08-31
```

The client installer writes it; `dosctl upgrade` rewrites it, **last and only
on success** -- a stamp claiming a build the machine did not receive is worse
than no stamp at all. `dosctl version` reads it back over the wire and prints
it next to what this bridge would send.

**The `+` matters.** A packaged installer stamps a bare `build 1`. `dosctl
upgrade` sends whatever is in the working tree, which is normally *ahead* of
the last build cut, so it stamps `build 1+` -- "at least build 1". Claiming a
plain build number for an unpackaged tree would be a lie the moment anyone
edited a `.pas` file.

A box with no `VERSION.TXT` predates stamping or was installed by hand;
`dosctl version` says so rather than guessing, and the next upgrade fixes it.

Note `AUTOEXEC.BAT` and `CONFIG.SYS` are **not** upgradeable this way and
should not be. A bad `AUTOEXEC.BAT` breaks the network before the agent runs,
which is unrecoverable from here; `CONFIG.SYS` is worse still.

## Writing network tools in Pascal

FPC has **no TCP/IP stack for `-Tmsdos`** -- no `Sockets` unit, no resolver,
nothing. Two routes exist and they differ enormously in ambition:

**Shell out to mTCP.** `C:\NETWORK\MTCP` holds `PING`, `NC`, `HTGET`, `SNTP`,
`DNSTEST`, `FTP`, `TELNET`, `SPDTEST`, `PKTTOOL` and more. Drive them with
`dosexec` and read their output. Nothing to build, but you get only what they
already do.

**Talk to the packet driver.** This is the layer mTCP itself sits on: a small,
documented interrupt API published by a resident driver on one vector in
60h..80h. `starter/pktdrv.pas` is the entry point. It finds the driver by the
`PKT DRVR` signature the spec places at offset 3 of the handler, then calls
`driver_info` (AH=1Fh). On this box:

```
INT 60h  name NE2000, spec 11, class 1 (DIX Ethernet), type 54, funcs 2
```

Note the name. `AUTOEXEC.BAT` loads `C:\drivers\pm2000.com`, but PicoMEM's
driver presents an NE2000-compatible interface and reports itself as `NE2000`.
Both statements are true: the file is not the name.

Calling a vector known only at run time needs a trick, because the `INT` opcode
takes an immediate operand. `pktdrv.pas` reads the vector out of the table and
does `PUSHF` followed by a far `CALL`, which leaves the stack exactly as `INT`
would and unwinds correctly on the driver's `IRET`. The fiddly part is that the
call returns with `DS` pointing at the *driver's* segment, so until `DS` is put
back every global in the program is unreachable and storing a result would
write into the driver. Move what you need into registers first, restore `DS`,
then store -- `MOV` does not touch the flags, so the carry the driver returned
is still valid when you test it.

### Capturing frames: `PKTCAP`

`starter/pktcap.pas` is the next step up and the only program here that calls
`access_type` (AH=02h). Verified on hardware 2026-08-31 -- eight seconds of ARP
gave six frames, zero dropped, and the bridge was unaffected:

```
    destination  : FF:FF:FF:FF:FF:FF        (broadcast)
    source       : AA:BB:CC:11:22:33
    ethertype    : 0806  (ARP)
      0000  FF FF FF FF FF FF AA BB CC 11 22 33 08 06 00 01
      0010  08 00 06 04 00 01 AA BB CC 11 22 33 C0 A8 01 28
      0020  00 00 00 00 00 00 C0 A8 01 D3 ...
```

which decodes as 192.168.1.40 asking who has 192.168.1.211.

Three things in it are load-bearing:

* **`access_type` hands the driver a far pointer to your code**, which it then
  calls at interrupt time for every matching frame. Exit without
  `release_type` (AH=03h) and that pointer dangles into memory DOS has since
  reused -- the next matching frame jumps into it. That is a box with no
  network, and the bridge runs over that network, so recovery needs hands on
  the keyboard. Everything between acquire and release is straight-line code
  with **no DOS calls and no WriteLn**; nothing is printed until the handle is
  back.
* **A frame delivered to your handle is not delivered to mTCP's.** `ALL` takes
  every frame away from the stack this bridge uses, so it is opt-in and the
  default is ARP -- broadcast, frequent, and not something an established
  connection depends on moment to moment.
* **The receiver runs at interrupt time with `DS` belonging to the driver**, so
  none of the program's data is reachable until `DS` is replaced. The first
  fourteen bytes of `PktRecv` are hand-written `db`/`dw` precisely so the two
  words needing run-time patching sit at known offsets `+7` (data segment) and
  `+12` (`Ofs(Shared)`). Let the assembler choose the encoding and those
  offsets stop being knowable from Pascal. **If you edit that prologue, re-check
  the offsets against the linked binary before running it** -- a wrong patch
  corrupts an interrupt-time routine, which fails at the worst possible moment.

The driver calls the receiver twice per frame: `AX=0` asks for a buffer of
`CX` bytes (return `ES:DI`, or `0:0` to drop it), `AX=1` says it has been
copied in. A `Busy` flag makes the second call's buffer safe to read from the
main loop: while it is set the handler returns `0:0` and counts a drop rather
than overwriting a frame being read.

### Transmitting: `ARP`

`starter/arp.pas` sends as well as receives, and the striking thing is how much
easier sending is. `send_pkt` (AH=04h) takes `DS:SI` and `CX` and nothing
else -- no handle, no callback, no interrupt-time code, nothing to release. All
the care in `pktcap.pas` is about the receive path; the transmit half here is a
dozen lines.

ARP was the right first thing to send: complete in 42 bytes, no IP stack
needed, and a reply proves both directions of the driver at once. Verified on
hardware 2026-08-31:

```
ARP 192.168.1.1        ->  192.168.1.1   AA:BB:CC:44:55:66
ARP -scan 192.168.1    ->  every host that answered, MAC for each
```

`get_address` (AH=06h) is in there too -- it needs the handle, so it lives
between Acquire and Release. On a PicoMEM the address it returns carries a
Raspberry Pi OUI (`28:CD:C1`), because what answers is the card's own WiFi
radio rather than anything NE2000-shaped.

**A bug worth keeping as a warning.** The first version guessed our own sender
address as `.0` of the target's range and got *no replies at all*. The packet
driver has no idea what our IP is -- addresses are a concept one layer up -- so
it has to come from somewhere, and `.0` is a network address that well-behaved
hosts are right to ignore. `arp.pas` now reads `IPADDR` from the file
`%MTCPCFG%` points at, the same place every mTCP tool looks, with `-ip` to
override. If a tool here ever transmits and hears nothing back, suspect the
sender address before suspecting the wire.

### IPv4 and UDP without mTCP: the `Net` unit

`starter/net.pas` is IPv4 and UDP on top of the packet driver, and it is step
one of getting rid of the mTCP dependency entirely. **Verified on hardware
2026-09-02** against Cloudflare's anycast NTP server, which is off-subnet, so
the gateway path was exercised too:

```
  packet driver  : INT 60h
  our address    : 192.168.1.20  28:CD:C1:00:11:22
  server         : 162.159.200.1  via gateway 192.168.1.1 at AA:BB:CC:44:55:66
  leap / mode    : LI=0  mode=4  stratum=3
  server says    : 2026-09-02 04:59:58  UTC
```

```pascal
uses Net;

NetReadConfig;              { IPADDR / NETMASK / GATEWAY out of %MTCPCFG% }
NetOpen(PeerIP);            { find driver, ARP the peer or the gateway }
NetUdpSend(SrcPort, DstPort, Buf, Len);
NetUdpRecv(Port, Buf, Max, Got, TimeoutTicks);
NetClose;                   { MANDATORY -- see below }
```

**A real server is the only worthwhile test.** An echo bounced off our own
daemon would pass even if both ends agreed on the same mistake; an NTP server
validates the UDP checksum, validates the addresses, and answers in a format we
did not invent. `NTP.EXE` and mTCP's `SNTP` were pointed at the same server
seventeen seconds apart and agreed **to the second** -- two independent stacks,
which is the check that means something.

Four things in it are load-bearing:

* **`NetClose` on every exit path, including the error ones.** Same rule as
  `pktcap`: the driver holds a far pointer to our receiver, and exiting without
  releasing leaves it dangling into memory DOS reuses. The next matching frame
  jumps into it, and the bridge runs over that network.
* **Two handles are never held at once.** The spec lets a driver refuse a
  second `access_type` for a type already in use, so the ARP phase opens 0806,
  finishes, releases, and only then does the IP phase open 0800. Sequential,
  never concurrent -- which is also why this can coexist with mTCP at all.
* **The checksum accumulator is 16-bit with an end-around carry**, not a 32-bit
  sum. `BENCH` puts 32-bit arithmetic at 5-8x its 16-bit equivalent, and a
  checksum is the one thing every packet pays for.
* **Fragments are dropped, not reassembled.** Nothing the bridge sends needs
  fragmenting, and a wrong reassembly is worse than a retry.

Note `NTP.EXE` takes an address, not a name -- there is no DNS here. That is not
worth fixing for the bridge, which only ever talks to one host by IP. It also
means the default (the configured `GATEWAY`) often does not answer: this router
does not serve NTP, and mTCP's `SNTP` times out against it in exactly the same
way, which is how we established our stack was not the problem.

### Moving off mTCP: TFTP over our own UDP

**Done and running on hardware 2026-09-02.** The job poll, every file fetch
and every result now go over our own stack by default, with mTCP kept as the
fallback on each one.

| | |
|---|---|
| `starter/tftp.pas` | TFTP client, both directions, on top of `Net` |
| `starter/uget.pas` | `UGET` -- fetch. Replaces `HTGET` |
| `starter/uput.pas` | `UPUT` -- send. Replaces `NC` |
| `dosd.py` | TFTP server on **UDP 8069**, plus the `job` resource |

TFTP rather than a reimplementation of HTTP, because "our own HTGET and NC"
means writing TCP -- HTTP runs on TCP and `NC` is a TCP client -- and TCP's
failure mode is the one that cannot be tolerated here: correct on the bench,
silently corrupting under loss, in the component whose failure needs hands on
the keyboard. TFTP is four opcodes and one packet in flight, and every failure
it can have is a visible timeout.

Verified byte-exact in both directions by CRC-32, which is the check that
means something -- `HD` on the box and `zlib.crc32` on Windows agree:

```
files/starter/HELLO.EXE   26118 bytes  CRC-32 A78BF602      (Windows)
C:\WORK\UT.EXE            26118 bytes  crc32  A78BF602      (after UGET)
files/local/UPTEST.BIN    26118 bytes  CRC-32 A78BF602      (after UPUT back)
```

**Everything falls back.** Each transfer tries UDP and drops to `HTGET`/`NC`
if the tool is missing or the transfer fails, so a bug degrades into a slower
job instead of a silent box, and both routes stay exercised. The two never
collide: they are separate programs, so they never hold a packet driver handle
at the same moment.

Four things that are load-bearing:

* **Stop-and-wait makes the disk safe.** Writing to a file while a packet
  handle is open would normally race the receiver, which drops anything
  arriving while its buffer is busy. With stop-and-wait the server does not
  send block N+1 until it has our ACK for N, so nothing is on the wire while
  we are in DOS. Do not "optimise" this into a windowed transfer.
* **A duplicate DATA block must be re-ACKed and NOT written.** That is the
  classic way a stop-and-wait transfer corrupts silently.
* **The server answers from a new port.** TFTP's transfer identifier is an
  ephemeral port, not the well-known one, so `Net` reports `NetFromPort` and
  the client locks onto it. Keep replying to 8069 and a correct server ignores
  you -- which looks exactly like a server that is not running.
* **The job poll never retransmits its request.** dosd holds a job request
  open for `POLL_HOLD_SECS` -- 2 seconds since 2026-09-02, 8 before that; a
  retransmit would read as a second poll and take a second job off the queue.
  `UGET ... POLL` therefore makes one attempt and gives up. It used to fall
  through to `HTGET`; there is no fallback now, so it just waits for the next
  cycle. dosd deduplicates a repeat request from an address it is already
  holding one for, which is the other half of making that safe.

**The cost of that rule, measured:** file transfers never fail (208 blocks,
zero resends) because a lost request is simply resent, while the job poll
fails outright on a lost request -- observed at roughly one poll in five on
this WiFi link, each costing 11 seconds before the fallback. Correct, but not
free. Making the poll reliable enough to drop `HTGET` altogether needs
at-least-once delivery: requeue on failed dispatch (**done** -- a job whose
UDP delivery fails is put back rather than lost), plus client retransmit with
server-side deduplication so a resent request joins the existing wait instead
of starting a second one.

`UGET` and `UPUT` deliberately do **not** `uses About`. The loop runs them
every poll, and About prints from its unit initialisation -- linking it
repainted the attribution banner on the console every eight seconds, which is
the papercut this whole exercise was meant to remove. Same reasoning as
`KEYHIT.COM` being hand-assembled. They are also silent on success (`-V` for
the numbers), so the boot banner now survives instead of scrolling away.

### What is still left

**mTCP is gone. Not reduced -- gone.** The job poll, every file fetch, every
result and the binary pull all run on our own UDP, and on 2026-09-02 the last
`HTGET` line came out of `AI.BAT` too. Nothing the bridge does touches
`C:\NETWORK\MTCP`; what is left there is diagnosis you may or may not have.

The **packet driver is still required** and is a different thing -- it is the
driver for the network card, not part of mTCP.

`SET SRV=` stays in `AI.BAT` even though nothing on the box reads it now. It is
half of the address check `dosctl upgrade --agent` runs, which is what stops an
upgrade installing an agent pointed somewhere the machine cannot reach.

**The pull was the last one, and the least obvious.** Two things forced it out
beyond the dependency itself. `NC` printed a **thirteen-line version banner
straight to the console** on every pull -- `> NUL` was already on the line and
made no difference, because COMMAND.COM 6.22 has no stderr redirection at all,
so it could not be silenced from a batch at all. And `-bin` was load-bearing
with nothing on the wire enforcing it: without it `NC` opened stdin in text
mode and silently ate every 0x0D and 0x1A, so a 27298-byte `SYSINFO.EXE`
arrived as 27258 -- corrupt but entirely plausible-looking. TFTP is a block
protocol with a byte count, so there is no text mode to get wrong and nothing
to opt out of.

Verified byte-exact on hardware 2026-09-02: `C:\TOOLS\SYSINFO.EXE` pulled
over the new path, 28928 bytes, CRC-32 `EB1ABFF1` matching the Windows copy.
The bytes arrive under the reserved TFTP name `pull` and land in the same sink
the NC port used, so `dosctl pull` did not change. The TCP listener on 8082 is
kept anyway -- it costs one idle socket and is the only way bytes could still
arrive from a box running a batch generated by an older `dosd`.

Every transfer is verifiable end to end, which is what made all of this safe to
attempt: `HD`'s CRC-32 matches Python's `zlib.crc32`, so silent corruption is
detectable from either side.

#### The number that made dropping `HTGET` safe

The fallback was kept because roughly one poll in five got no reply, and that
was the right call at the time -- but the figure was the wrong thing to look
at. Measured properly on 2026-09-02 by logging `dosd` to a file and counting:

```
24 job polls served, 4 with no ACK  (17%)
[12:06:22]    idle batch -> 192.168.1.20:22358  NO ACK
[12:07:40]    idle batch -> 192.168.1.20:23928  NO ACK
[12:08:35]    idle batch -> 192.168.1.20:20831  NO ACK
[12:09:30]    idle batch -> 192.168.1.20:21829  NO ACK
```

**Every single failure is an `idle batch` -- the "nothing for you" reply. Not
one job dispatch was ever lost.** That is what makes the fallback dispensable:
losing an idle reply costs the box one wasted cycle (UGET gives up, the offline
branch waits 5 seconds, it polls again) and nothing else. A job queued in that
window is picked up on the next poll, and `dosd` already requeues a dispatch
that goes unacked.

The honest cost of removing it: in the polls that miss, a job arriving just
then waits up to about 16 extra seconds, because `HTGET` used to pick it up
over TCP the moment UDP failed. Latency, not loss -- and the miss rate went
from 17% to 2.2% the same day, once the poll hold below was fixed, so the
expected cost of having dropped the fallback is now about an eighth of what it
looked like at the time.

**The mechanism, finally observed rather than inferred.** Watching this host's
ARP table while the box polled:

```
12:10:48    192.168.1.20   28-cd-c1-00-11-22  dynamic
12:10:56    192.168.1.20   28-cd-c1-00-11-22  dynamic
12:11:04  (no entry for .66)
12:11:12    192.168.1.20   28-cd-c1-00-11-22  dynamic
```

The entry **comes and goes**. Each poll's ARP exchange refreshes it and it
lapses in between, and **nothing on the box ever answers an ARP request** -- by
the time the IP phase is running, `Net` has released the 0806 handle and holds
only 0800, so it does not even see the query. Any reply `dosd` has to send
during a gap is therefore undeliverable.

That also explains why only idle replies suffer: a job dispatch goes out
promptly, while the entry is still fresh from the poll's own ARP, whereas an
idle reply waits out the server's hold first.

Shortening the hold to 2 seconds fixed this, and **answering ARP would add
nothing to it** -- see below, where that idea was built, tested and thrown
away.

### Large transfers: fixed, and what it took

**Multi-megabyte transfers work and are byte-exact.** Verified on hardware
2026-09-02, CRC-32 checked on the box against `zlib.crc32` on Windows:

| | blocks | resends | time | CRC-32 |
|---|---|---|---|---|
| 300 KB | 601 | 1-7 | ~25s | `1FF2AF8D` |
| 1 MB | 2049 | 11 | ~90s | `1DA381B3` |
| **5 MB** | **10241** | **53** | **7m 39s** | `07E75E7F` |

About 11.4 KB/s. The same 300 KB file failed **6 times out of 6** before this
work, and the 30-47 KB tool deploys failed about 11% of the time.

#### Two real bugs: the same mistake in both directions

Both ends treated an unexpected packet as a reason to keep waiting, when a
**duplicate ACK is information**: it means the packet you last sent is gone.

* `dosd.py`, serving a download: on any non-matching packet it went back to
  `recvfrom` with a **fresh 2-second timeout**. A client that has timed out
  re-ACKs the previous block every 2 seconds, and each of those reset the
  server's timer -- so the server never retransmitted the lost block while
  the client sat waiting for it. **A deadlock, from one lost packet.**
* `starter/tftp.pas`, sending an upload: identical, mirrored. A stale ACK did
  `Inc(TftpDups)` and looped. It had never been hit because a result is only
  a block or two -- it would have broken the first large `dospull` anyone
  tried.

Both now retransmit immediately on a duplicate ACK.

**One lost packet was enough**, which is why it looked size-dependent: 68-block
transfers nearly always got through untouched, 600-block ones never did.

#### A third bug: every transfer truncated to 513 bytes

Introduced on 2026-09-02 by the `blksize` work and found the same evening,
after it had stranded the box and cost hours of blaming the hardware. The
whole thing is one shadowed name in `tftp_send_blob`:

```python
def tftp_send_blob(sock, addr, blob, retries=None, blk=None):
    blk = TFTP_BLK                              # blk is the block SIZE
    chunk = blob[off:off + blk]
    op, blk = struct.unpack("!HH", data[:4])    # ...now the block NUMBER
    if len(chunk) < blk:                        # ...compared against a number
```

The first ACK rewrites the block size to 1. So every transfer sent 512 bytes,
then a **single byte**, which the client correctly read as a short final block
and treated as a complete file. **513 bytes, and both ends believed it.**

What makes it worth recording is how convincingly it framed the DOS box:

* **A job batch ran.** 513 bytes is the head line and the first command or
  two; the `RES.TXT` write and the closing `UPUT` live at the end of the
  batch and were simply not in the file. So the program ran, nothing ever
  reported, and the agent loop carried on polling -- which reads exactly like
  a broken result path.
* **Every idle poll logged `NO ACK`.** The idle batch is under 512 bytes, so
  the client got it whole and stopped; the server marched on to a phantom
  block 2 and retransmitted to nobody for ten seconds. 100% failures on a
  link that was completely healthy.
* **A deploy of `UGET.EXE` wrote a 513-byte file over it.** With no mTCP
  fallback left, that stranded the machine and needed hands on the keyboard.

Three separate symptoms, all pointing at the box, none of them its fault. The
hours went into ARP, packet driver handles, firewall rules and CRCs on tools
that turned out to be fine, because **the daemon's log lived only in its
console window** and nobody reading it could see that `acked` had become
`NO ACK` on every line. That is why `log()` now mirrors to `dosd.log`.

The lesson that generalises: a transfer protocol whose length check and whose
sequence check share a variable can agree with itself perfectly and still be
wrong. Both ends here were internally consistent -- the client's "short block
means done" is correct TFTP -- so nothing detected it. Only comparing the
delivered byte count against the source did, which is what the CRC-32 check on
deploys now does automatically.

#### The workaround: resume on stall

There is a second fault underneath, and it is **still unexplained**. Partway
through a transfer, frames addressed to the box's MAC stop being delivered to
it, while broadcast frames keep arriving perfectly well. The server is provably
still sending. It is not a lost packet and not a shortage of patience.

What always works is a **completely fresh flow** -- every transfer that stalled
succeeded on the next attempt. So `TftpGet` builds one for itself after three
silent timeouts: `NetClose`, `NetOpen` (which redoes ARP), a new local port,
and a re-request for the rest of the file. `dosd` accepts `name@<byte offset>`
in an RRQ and serves from there; the file stays open and keeps appending, so
nothing already received is fetched twice.

Verified in the act, not just in theory -- dosd logged the resumes:

```
tftp: 192.168.1.20 resuming local/BIGTEST.BIN at byte 8192
tftp: 192.168.1.20 resuming local/BIGTEST.BIN at byte 130048
tftp: 192.168.1.20 resuming local/BIGTEST.BIN at byte 248832
```

Every offset is a multiple of 512, and the result CRC-matched.

#### Four hypotheses that were wrong

Recorded because each one is plausible enough to be tried again, and each was
**built, measured and removed** -- the code is gone, the null results are not:

| theory | how it died |
|---|---|
| ARP entry expiring mid-transfer | `NetArpPoke` broadcast an ARP before every retransmit. Fired 10x per stall, changed nothing; `arp -a` showed the entry present throughout |
| just the deadlock | fixed it, and 3 of 3 still failed at blocks 80-89 |
| the receive handle wedges | `NetReopen` released and re-took it. `reopens: 3` and still stalled -- and broadcasts kept arriving, so the handle was fine |
| the card's address filter | `set_rcv_mode(6)`, promiscuous. `modesets: 3`, no blocks arrived even with the card accepting everything on the wire |

**The measurement that cracked it was a null result.** Raising the client's
retry budget from 10 to 60 -- two full minutes of asking -- changed nothing at
all. That is what ruled out impatience and transient outages together, and left
only something scoped to the flow, which is exactly what rebuilding the flow
fixes. The experiment that looked like a waste was the one that mattered.

#### Bigger blocks: `blksize`, and what it actually bought

RFC 2348, client-driven, verified on hardware 2026-09-02. `UGET` asks for
1400-byte blocks on a file fetch; `dosd` answers with an OACK naming the size
it accepted, and the client ACKs block 0 to start the transfer.

The ceiling is **1400** and the reason is `Net`, not TFTP: one Ethernet frame
is 1500 bytes, less 20 for IP and 8 for UDP and 4 for the TFTP header, giving
1468 -- and `Net` **drops fragments rather than reassembling them**, so
anything above that would not merely be slower, it would not arrive at all.
1400 leaves headroom for that arithmetic being wrong somewhere.

Measured back to back on the same link and the same 1 MB file, the old client
kept runnable as `C:\TOOLS\UGET.BAK`:

| | blocks | resends | time | |
|---|---|---|---|---|
| 512-byte blocks | 2049 | 27 | 131.2s | 8.0 KB/s |
| **1400-byte blocks** | **749** | **7** | **72.3s** | **14.5 KB/s** |

**1.8x, not the 2.7x the packet count suggests**, because per-byte cost on an
8086 -- the copy and the UDP checksum -- does not go away when you send fewer
packets. Fewer packets does also mean proportionally fewer chances to lose
one, which is where the resend count went.

Three things in it are deliberate:

* **The job poll does not negotiate.** `TftpWantBlk` is set to 0 for a poll
  and only raised for a real fetch. A batch is a block or two, and an OACK
  round trip on every poll would cost more than it could ever save.
* **A resumed flow re-negotiates from scratch.** `TftpBlkSize` is reset to
  512 when `TftpGet` rebuilds its flow after a stall, because the new request
  is a new negotiation and assuming the old answer would silently mis-frame
  every block after it.
* **Asking is free against an old server.** An option a server does not
  understand is ignored, and it simply sends 512-byte blocks -- so a new
  client works against an old `dosd`, and an old client (which asks for
  nothing) works against a new one.

#### The upload direction, and the first `dospull` that ever worked

`UPUT` negotiates the same way, and the OACK replaces ACK 0 rather than
joining it -- a server sending both would be answered twice. Unlike a read,
the client does not ACK the OACK: its first DATA block is the answer.

**Large `dospull` had never worked, and blksize is not why.** The first 1 MB
pull ever attempted stalled at block 5, and the retry stalled at block 401 --
scattered, which is this link's mid-transfer stall, the same fault the
download path has worked around since the 5 MB transfers. `TftpGet` rebuilt
its flow on a stall; `TftpPut` had no equivalent and simply gave up. The note
above about the upload deadlock predicted this exactly: *it would have broken
the first large `dospull` anyone tried*. It did.

So `TftpPut` now does what `TftpGet` does -- after `RESTART_AFTER` silent
timeouts it tears the flow down, re-opens, and re-requests as
`name@<bytes acked>` -- and `dosd` keeps the partial write across flows in
`_uploads`, keyed by client address and name.

Verified on hardware 2026-09-03: 1 MB, four stalls, four rebuilt flows, one
byte-exact file (CRC-32 `998E4325`).

```
resuming write of pull at byte 533400
resuming write of pull at byte 635600
resuming write of pull at byte 695800
```

Three things in it are load-bearing, and two of them were bugs first:

* **A resume rewinds; it does not have to match.** The client resumes from
  the last byte *it* saw acknowledged, so it is normally BEHIND the server:
  every ACK we sent whose reply was lost leaves us holding a block the client
  still believes it owes. The first version demanded `len(held) == resume_at`
  and refused the very first real resume -- `cannot resume write of pull at
  byte 14000`. Only resuming *past* what we hold is refused, because nothing
  can fill that gap and appending anyway would produce a plausible file with
  a hole in it.
* **The resumed buffer is a fresh copy, not a truncation in place.** The
  stalled flow may still be inside its retry loop on another thread holding a
  reference to the old object, and two writers interleaving into one buffer
  is a corruption nobody would trace.
* **A duplicate ACK never counts towards a restart -- only silence does.** A
  duplicate ACK is proof the far end is alive and listening, which is the
  opposite of a stall; the right answer there is an immediate retransmit.
  Restarting the flow would throw away a working connection.

#### Limits worth knowing before moving big files

* **~33 MB per transfer.** The TFTP block number is 16 bits, so 65535 blocks
  of 512 bytes. 5 MB is 10241 blocks, so there is headroom, but it is a real
  ceiling and nothing checks for it.
* **Raise `--timeout`.** 5 MB takes nearly eight minutes against a 120s
  default.
* **`blksize` (RFC 2348) is done** -- see below. 1.8x, measured.
* **The single-slot receive buffer drops frames under retransmit bursts** --
  100 of them during the 5 MB run. Harmless, because they are retransmitted,
  but it is the next thing to look at for speed.

### The original investigation: large transfers are NOT ARP

Kept as history: this is how the large-transfer problem looked while it was
still open, and the reasoning is why the ARP theory got as far as it did. The
outcome is in the section above.

**What works.** Anything up to about 90 blocks is completely reliable. Thirty
consecutive 34 KB fetches moved 2040 blocks with **zero resends** -- so the
link does not drop packets in any ordinary sense, and the earlier claim in
these notes that "the residual matches raw link loss" was wrong.

**What does not.** A 300 KB file (600 blocks) failed **6 times out of 6**,
stalling at scattered points -- blocks 89, 20, 21 on one build and 85, 32, 86
on another. Bulk deploys of the 30-47 KB tools fail about 11% of the time
(4 of 36 on a `--force` resend), and those four came in *alphabetically
consecutive pairs* -- AMOZART/ARP, then VMODES/VSHOT -- so whatever it is
catches the transfer in flight and the one after it.

**ARP was the obvious suspect and it is not the cause.** Worth recording,
because it is a plausible enough story to be tried again by someone else:

* `starter/net.pas` grew a `NetArpPoke` -- broadcast an unsolicited ARP
  request before every retransmit, so the far side refreshes its entry for us.
  `send_pkt` (AH=04h) needs no handle, so this was main-loop code with no
  interrupt-time risk at all.
* It fired **10 times per failed transfer** and made **no difference**: 6 of 6
  still failed, at the same scattered block numbers as without it.
* Watching `arp -a` on the Windows side *during* a stall showed the entry
  **present the whole time**.

So it was reverted -- the rebuilt `UGET.EXE` is byte-identical to the one on
the box (47158 bytes, CRC-32 `94F4A595`), which is how the revert was checked.
Keeping an unproven fix in the transport is exactly the trap `TFTP_HOLD_SECS`
set: a plausible change that measures as nothing gets cited later as a reason
the cause must lie elsewhere.

**Practical impact today: none.** Every tool in the kit is under 50 KB, and
the largest, `UGET.EXE` at 47 KB, deploys fine (occasionally on the second
attempt -- which is what the CRC check above is for). But there is a ceiling
here, and anything that needs to move a few hundred KB will hit it.

**To reproduce**, serve a big file and fetch it:

```python
b = bytearray(); x = 12345
while len(b) < 300*1024:
    x = (x*1103515245 + 12345) & 0x7FFFFFFF
    b.append((x >> 16) & 0xFF)
open(r"files/local/BIGTEST.BIN", "wb").write(bytes(b))
```

```
dosexec "C:\TOOLS\UGET.EXE <server> local/BIGTEST.BIN C:\WORK\B.BIN -V"
```

It fails within a minute, every time. **Do not start from the ARP theory** --
that ground is covered. The untried leads are the DOS side's file writes as
the file grows (FAT allocation pauses long enough to desynchronise the
stop-and-wait), and `PKTCAP` on the box to see whether the server's blocks are
arriving at the wire and being lost above it.

**TCP is a different category and should not be written here.** Sequence
arithmetic, the connection state machine, retransmission timers, windowing,
out-of-order reassembly. Its failure mode is the bad one: correct on the bench,
silently corrupting data under loss. Write TCP only if writing TCP is the point.

## Stopping the agent loop

Three ways, and they fail differently.

| | |
|---|---|
| **ScrollLock** at the box | clean. Noticed within one poll, always between jobs |
| **`dosctl stop`** from Windows | clean, same exit point. One-way: see below |
| **Ctrl-C** at the box | the hammer. Use it for a job that is genuinely stuck |

`AI.BAT` checks both signals at the **top** of the loop, before the `HTGET`
that fetches work. That ordering is the whole point: an exit taken after the
fetch would discard a job the server had already dispatched, and `dosd` would
then wait out its full timeout and report the box as hung -- blaming the
machine for doing what it was told, which is the failure this project keeps
having to design around.

Ctrl-C has no such safe point. Landing mid-`JOB.BAT` means the closing `NC`
never runs and the Windows side times out the same way; landing inside
`:TRYIT` leaves `TRYING.FLG` on disk, and the *next* boot then reports
`##BOOTFAIL rc=253` for a driver that was fine.

**`dosctl stop` is a one-way door.** Once the loop exits, the box sits at a
prompt with nothing polling, so nothing on the Windows side can reach it.
Restarting needs someone at its keyboard typing `C:\AI\AI.BAT`, or a power
cycle. `dosctl` says so before it acts, and then watches the box go quiet
rather than claiming success the moment the flag lands.

**Verified on hardware 2026-09-01**: a reboot into the new agent, ScrollLock
pressed at the keyboard, the loop stopped, and `C:\AI\AI.BAT` restarted it.
Note the box comes back with ScrollLock still *on* if you do not clear it --
the stop message says so, because the agent would otherwise quit again on
its first poll.

### The offline branch quit instead of retrying

**Observed on hardware 2026-09-03: the agent stopped polling on its own and
sat at a prompt.** No `STOP.FLG` had ever been staged, ScrollLock was off, and
the last two entries in `dosd.log` were consecutive `NO ACK`s on idle polls --
which is the only route into `:OFFLINE`.

The branch ended:

```
CHOICE /C:QY /N /T:Y,5 > NUL
IF ERRORLEVEL 2 GOTO LOOP
GOTO QUIT
```

and its comment claimed the fallback was safe: *"If CHOICE is missing the
errorlevel is whatever the poll left, which is >= 20, so this falls to
`GOTO LOOP`."*

**That was an `HTGET` property, and it died with `HTGET`.** `HTGET` returned
>= 20 even on success, which is the same quirk that forces every job batch to
verify with `IF EXIST` rather than an exit code. `UGET`'s code is deliberately
honest, and `uget.pas` returns **1** on a failed poll.

So the guard had silently inverted. Reaching that line at all means the poll
just failed, so `ERRORLEVEL` is 1; 1 is below 2; the agent quits. Every case
that is not a clean `CHOICE` timeout -- `CHOICE` failing to resolve, a
truncated `PATH` out of the nearly-full environment, a Ctrl-Break landing
inside it -- turns a network outage into a stopped agent on a box nothing can
then reach.

The fix forces a known `ERRORLEVEL` first, which makes the three cases
distinguishable again:

```
IF EXIST C:\AGENT\EXIT0.COM C:\AGENT\EXIT0.COM
CHOICE /C:QY /N /T:Y,5 > NUL
IF ERRORLEVEL 2 GOTO LOOP
IF ERRORLEVEL 1 GOTO QUIT
GOTO LOOP
```

| | |
|---|---|
| 2 | `CHOICE` timed out | keep polling |
| 1 | somebody pressed Q | stop |
| 0 | `CHOICE` never ran, or was interrupted | keep polling |

**Stopping is now the only outcome that needs positive evidence**, which is
the right way round for the one branch that cannot be undone from Windows.

Two things generalise:

* **A fallback that depends on another program's exit code is coupled to that
  program.** Nothing here referenced `HTGET`; the dependency lived entirely in
  a comment asserting a number. Replacing the transport could not have been
  expected to make anyone re-read it. If a branch relies on a stale
  `ERRORLEVEL`, run `EXIT0.COM` and make the reliance explicit.
* **`IF ERRORLEVEL n` is `>=`, so the default arm of any such ladder is
  whatever is left over.** Point the default at the recoverable outcome. Here
  the unrecoverable one was the default, and it took a transport change three
  weeks earlier to expose it.

The same hazard exists at the `KEYHIT` test and is already handled correctly
there -- `IF NOT EXIST C:\TOOLS\KEYHIT.COM GOTO NOKEY` means the test is
never reached with a stale value. That guard is why ScrollLock did not have
this bug.

### Why ScrollLock and not a keypress

The obvious design is to read the keyboard buffer and look for a letter. **It
cannot work here, and it fails silently.** mTCP's tools watch the keyboard so
ESC or Ctrl-Break can abort a transfer, and in doing so they *consume* whatever
is queued. The agent spends effectively all of its time inside `HTGET`
long-polling for a job, so a keypress is eaten before the loop looks at it.
Measured on hardware 2026-09-01, faking the keystroke by writing into the BIOS
buffer at `0040:001E`:

```
STUFFQ then KEYHIT             ->  rc 1   the key was there
STUFFQ then HTGET then KEYHIT  ->  rc 0   HTGET ate it
```

ScrollLock is not a queued keystroke at all -- it is bit 4 of the BIOS keyboard
flags byte at `0040:0017`, set by the keyboard ISR and touched by nothing else.
It survived the same test with the `HTGET` in the middle. It also has an LED,
so the machine displays its own armed state with nothing on screen.

`KEYHIT.COM` is 22 bytes of hand-assembled code, generated by
`starter/mkkeyhit.py` -- the listing and the byte table are the same file, so
they cannot drift. It is deliberately **not** an FPC program: the loop runs it
every eight seconds forever, and 25 KB of binary re-loaded each time would be
silly, quite apart from `uses About` repainting the attribution banner on the
console every eight seconds.

`CHOICE` in the `:OFFLINE` branch is the one place a real keypress works, since
`CHOICE` reads the keyboard itself. `Q` quits there.

## What the box says on its own screen

`AI.BAT` prints a boot banner: the build from `C:\AI\VERSION.TXT`, the job
server and result host it will use, and its own `IPADDR` read out of whatever
`%MTCPCFG%` points at. That last line exists because when this box went silent
on an expired DHCP lease, the screen looked perfectly healthy and said nothing
at all about the network.

**It used to scroll off within about a minute, and now it stays.** mTCP printed
a four-line version block on every poll, straight to the console; `> NUL` does
not catch it and COMMAND.COM 6.22 has no stderr redirection. With the poll
moved onto our own UDP the loop prints nothing at all, so the screen is now a
live status display rather than a scrollback.

The heartbeat this section predicted was built, and it is what makes the
silence safe: **`UGET` draws a spinner in place while it waits** -- one
character then a backspace, phase taken from the BIOS tick at `0040:006C`, so
it needs no state of its own and scrolls nothing. Jobs announce themselves as
they run, raw `dosexec` jobs included, which used to be silent. `UGET`/`UPUT`
are otherwise silent on success (`-V` for the numbers) and neither uses
`About` -- the loop runs them every poll and About prints from its unit
initialisation, so linking it repainted the attribution banner every eight
seconds. Same reasoning as `KEYHIT.COM` being hand-assembled.

Everything below is the reasoning from when mTCP still drove the loop. It is
kept because the argument is the important part, and it is exactly why the
spinner had to exist before the chatter could go.

`HTGET -quiet` **does** suppress it -- measured 2026-09-01: with it on, 55
seconds of idle polling left the screen completely unchanged, against roughly
seven version blocks without it. It was tried, and then taken back out.

The reason is worth keeping. That chatter is the **only continuous evidence the
box has not wedged**, and a machine that has stopped polling looks exactly like
a machine that is quietly waiting -- which is the failure this bridge keeps
having to design around, and the one that costs a walk to the keyboard. Four
noisy lines every eight seconds buys a heartbeat you can see from across the
room. Quieting them buys a readable banner nobody is looking at.

So treat the banner as a boot-time display. The stop message repeats the same
addresses, which is the other place to read them, and `dosctl version` /
`dosctl status` answer from this side.

If the banner ever does need to persist, the way to do it is not `-quiet` --
it is a tiny .COM printing a spinner character followed by a backspace, which
animates in place and scrolls nothing. Same trick as `KEYHIT`, about 30 bytes,
and it can take its state from the BIOS tick counter at `0040:006C` so it needs
none of its own.

`AI.BAT` also sets `TZ`, which `AUTOEXEC.BAT` does not. Without it mTCP refuses
to stamp file timestamps and says so on every poll -- a quarter of everything
on that screen was this one warning. It goes in `AI.BAT` and **not**
`AUTOEXEC.BAT` for the usual reason: a mistake in `AUTOEXEC.BAT` breaks the
network before the agent runs and needs hands on the keyboard, while a mistake
in `AI.BAT` is fixable over the wire.

The environment on this box is nearly full, so a `SET` in the agent can fail
with `Out of environment space`. That is survivable for `TZ` -- you lose the
timestamps and nothing else -- but it is why the banner reads `%MTCPCFG%`
directly rather than copying it to a working variable first. Copying it
*truncated the path* and made a present config file look missing.

### The DOS console is a status display, not a scrollback

Everything the loop prints is built to fit **78 columns**. The screen is 80
wide and the boot banner now stays on it, so a line that wraps costs two rows
and reads as damage rather than information. Two rules follow:

* **`dosd` truncates every console line it generates** (`job_head` /
  `job_foot`, `CONSOLE_COLS = 78`) and gives each job exactly two lines: what
  it is, and how it ended. The job id is cut to four characters -- enough to
  match a screen line against a line in dosd's log, where the full id would
  eat a tenth of the width for nobody's benefit.
* **`UGET`/`UPUT` messages are short by construction.** `Fit()` truncates,
  `Leaf()` drops directories, and the `Tftp` error strings were rewritten from
  prose ("gave up after 5 retries at block 46") into labels ("stalled at
  block 46"). A failure prints two lines: the reason, then the counters.

```
 server      : 192.168.1.10   (UDP 8069, HTTP fallback)
 address     : 192.168.1.20   mask 255.255.255.0
 gateway     : 192.168.1.1   from C:\AI\NET.CFG
 stop        : ScrollLock, or Ctrl-C
-------------------------------------------------------------------
[815b] exec 1 cmd(s): MEM /C
[815b]   ok
[cf49] exec 1 cmd(s): DIR C:\WORK
[cf49]   done
[e6ed] exec 1 cmd(s): C:\TOOLS\DEVS.EXE NOSUCHDEV
[e6ed]   rc 1 FAILED
[e9e3] pull C:\AI\VERSION.TXT
[e9e3]   sent
[1f72] run starter/HELLO.EXE
 uget: HELLO.EXE FAILED - stalled at block 3
       rx 28 (26 foreign, 1 dropped)  tx 14 (0 refused)
```

#### The footer wording, and the `rc 0` that was a lie

Every job ends in exactly one row, worded so a failure is legible from across
the room. Verified on hardware 2026-09-02, all six states:

| | |
|---|---|
| `ok` | the job's last command was an external program and it exited 0 |
| `rc 3 FAILED` | ...and it exited non-zero |
| `done` | the commands ran; nothing here can say whether they worked |
| `sent` | a pull shipped the file |
| `FAILED - not found` | a pull found nothing at that path |
| `FAILED - could not fetch X` | the job never got as far as running anything |

**It used to print `rc 0` for every job that survived, and half the time that
was a fabrication.** DOS internal commands -- `ECHO`, `DIR`, `DEL`, `COPY`,
`TYPE`, `SET`, `VER` -- never touch `ERRORLEVEL`, and `EXIT0.COM` has already
forced the ladder to read a clean 0, so a job made only of those reported a
confident `rc 0` that meant nothing: `DIR C:\NOSUCH` exits 0. Those now print
`done`, because whoever is reading that screen is standing at the machine with
no way to know which commands set an exit code. Removing misinformation was
worth more than adding information.

`IF` and `FOR` are deliberately classed as external (`sets_errorlevel` in
`dosd.py`). Either can invoke a real program, so their rc may well be genuine.
A possibly-stale number is merely unhelpful; `done` printed over a program that
actually failed would hide a failure, so the doubt resolves towards the number.

The result returned to Windows is **unchanged** -- it still carries `##RC`
either way, because that is `dosctl`'s contract. This is console wording only,
and the Hard-constraints rule about not trusting `dosexec`'s exit code for
internal commands still applies on the Windows side.

Also note `ok` and `rc 3 FAILED` are two single `IF`s, not one chained pair.
`ECHO` is internal so a chained `IF` would survive here, but that is not a rule
worth relearning inside a batch nobody can debug.

Batches are generated per job, so all of this landed on the next poll: no tool
rebuild, no `dosctl upgrade`, no reboot.

#### How long did it take: `ELAPSED.COM`

`starter/elapsed.asm` is the job stopwatch, and the odd thing about it is that
it prints the caller's text rather than just a number:

```
IF EXIST C:\TOOLS\ELAPSED.COM C:\TOOLS\ELAPSED.COM /S      right after the head line
...
IF "%RC%"=="0" C:\TOOLS\ELAPSED.COM [bd01]   ok            instead of ECHO
```

**That is forced by the one-row budget.** `ECHO` always terminates its line, so
nothing can be appended to a row `ECHO` printed -- and a job that spent a
second row saying how long it took would scroll the display away twice as
fast. So whatever holds the time has to print the whole row.

The time covers the **whole job, fetch included**, because the stash goes
immediately after the head line. That is the number somebody standing at the
machine is actually asking about.

Three details worth keeping:

* **It reads `0040:006Ch` directly, not `INT 1Ah AH=0`.** That call returns the
  midnight-rollover flag in `AL` and *clears* it, and DOS reads the same flag
  to advance the date -- so a stopwatch built on it would occasionally eat a
  day.
* **It trims trailing spaces off the command tail.** COMMAND.COM strips a
  redirection off the line but leaves the space that preceded it in the tail,
  so the identical footer arrived a column wider whenever the caller
  redirected. Alignment must not depend on the call site.
* **The footer group is guarded with `GOTO`, not `SET F=ECHO`.** The `SET`
  version is two lines instead of seven and was the first thing tried, but the
  environment on this box is nearly full: a `SET` failing with `Out of
  environment space` expands to nothing and leaves COMMAND.COM trying to
  execute the footer text as a command. A box without the tool falls back to
  plain `ECHO` and simply gets no time.

Only the low word of the tick is kept, so a job over about an hour -- or one
spanning midnight -- reports nonsense. Jobs here are seconds and dosd's own
default timeout is 120s, so 32-bit arithmetic for a status line is not worth
the bytes.

It is 293 bytes of NASM rather than the Python byte-table `KEYHIT.COM` uses,
because 130-odd hand-encoded bytes with hand-computed jump displacements is not
reviewable. `nasm` ships with FPC, and `cpu 8086` in the source makes the
assembler enforce the baseline instead of a read-through:

```
nasm -f bin elapsed.asm -o build/ELAPSED.COM
```

The directive is wrapped in `%ifndef __MININASM__` so the file still builds on
the DOS box itself.

#### A job shows its output on the box, too

Default on since 2026-09-02: a job's captured output is `TYPE`d onto the DOS
console between the head line and the footer, so the machine in front of you
can show what it actually said and not only what it was asked to do. The result
still goes back over the wire exactly as before -- this is a second copy, for
the screen.

```
[eb32] exec 1 cmd(s): C:\TOOLS\MOZART.EXE
DOS Bridge tools  --  StevenC  --  built 2026/09/01
=== Mozart, Eine kleine Nachtmusik K.525 (opening) -- PC speaker ===
  ...
--- 3 passed, 0 failed ---
[eb32]   ok  11.1s
```

**This is the one thing here that deliberately breaks the two-lines-per-job
budget**, and it does scroll the banner away sooner -- a `MEM /C` is twenty-odd
rows. That is the trade for being able to read a job at the machine, and it is
reversible three ways:

| | |
|---|---|
| `dosrun --quiet`, `dosexec --quiet` | this job only |
| `DOSD_ECHO_OUTPUT=0` in dosd's environment | the default, for a session |
| nothing to change on the box | it is generated per job |

Long output lines still wrap -- MOZART's melody line is 120 columns. That is
deliberate: truncating a data dump to fit would hide the data, and the
*status* lines are the ones that must never wrap.

`dosctl`'s own bookkeeping jobs pass `echo=False` explicitly -- the version
`TYPE`, the `C:\TOOLS` listing, the stop flag. A 36-file `DIR` on the console
every upgrade is nobody's idea of a status display.

**And a documented switch is not a switch.** `DOSD_ECHO_OUTPUT=0` was written
up here before it was tried, and it did nothing: `dosctl` sent `"echo"` on
*every* job, and dosd consults its own default only when the job does not carry
one -- so the environment variable was dead for precisely the two commands it
exists to govern. `dosctl` now sends that key only to turn the echo *off*.
All three paths are verified on hardware: default on, `--quiet`, and the
environment override.

**A flag added to the parser is not a flag.** `--quiet` was added to
`dosctl.py`'s `argparse` and did nothing: the tail is `argparse.REMAINDER`, and
a hand-written list right beside the parser decides which arguments are ours
versus the program's. `--quiet` was not in it, so it fell through into the
command tail and the DOS box tried to **execute** it -- `Bad command or file
name`, and a job reporting two commands when it was given one. That list is now
derived from the parser's own actions, so the two cannot drift again.

#### An outage says so once, not once per retry

A dosd restart used to cost two screen lines per failed poll -- `uget: job
FAILED` plus its counter line, forever -- and eight pairs of them scrolled the
banner away during one daemon restart. Fixed in two halves:

* `UGET` is **silent on a failed `POLL`** unless `-V`. A poll that gets no
  reply is the normal state of a box that cannot reach its server, not an
  event; the counters are still there for diagnosis.
* `AI.BAT` prints `[offline]` **once per outage**, guarded by
  `C:\AGENT\OFFLINE.FLG`, and prints `[online] ... is answering again` when a
  job finally arrives. The retries show as `UGET`'s spinner, which animates in
  place and scrolls nothing.

**It takes two consecutive misses to say anything, and that only became clear
after `HTGET` was removed.** With the fallback gone, every lost idle poll --
about one in six on this link -- fell into the offline branch, so a single
dropped packet printed an `[offline]` and then an `[online]` on the very next
poll. Two lines for something that cost five seconds and lost nothing, three
times over in one screenful. `HTGET` had been hiding it.

So the first failure sets `OFFLINE.FLG` and says **nothing**; only a second
consecutive failure prints, and it sets a second flag, `OFFSAID.FLG`. Recovery
prints `[online]` only if `OFFSAID.FLG` exists -- otherwise the notice would
reappear for an outage nobody was ever told about. Both are cleared at agent
startup. A dropped packet is now completely silent; a server that is really
gone still says so once.

**And on its own it bought nothing, because the premise was wrong.** The
failures were not isolated single drops at all -- they arrived in *consecutive
pairs*, so every pair tripped the threshold and printed anyway. dosd's log is
what showed it:

```
[12:20:13]  idle batch -> :21245  NO ACK
[12:20:36]  idle batch -> :21661  NO ACK
[12:20:43]  idle batch -> :22080  acked
```

The rule was behaving exactly as written; two consecutive misses is what it was
told to report. Chasing *why* they came in pairs is what found the real bug
below -- and with that fixed the misses are isolated again, which is the case
this rule was built for. Worth remembering as a pattern: a mitigation that
changes nothing is usually evidence about the cause, not a failed fix.

This is still the same shape as the difference between an average frame rate
and `FlipLate` in the scroller notes: the interesting question is rarely "did
something go wrong" but "did it go wrong twice in a row".

### The poll hold was the bug, and it was 8 seconds of dead code

**`serve_job` holds for `POLL_HOLD_SECS`. The `TFTP_HOLD_SECS = 2` added when
the hold was supposedly "reduced 8s to 2s" was never read by anything.** That
is why this file used to say shortening the hold "did not clear it" -- the hold
had never changed. It was 8 seconds the whole time, and the note recording that
non-result was itself the evidence of an unapplied change.

Why the number matters, and it is not obvious: every poll *begins* with the DOS
box ARPing for us, which is what puts this host's ARP entry for the box into a
state it can actually send to. dosd then sits on the request. Answer 8 seconds
later and that entry may already have gone stale -- and **nothing on the box
answers the re-probe**, because by then `Net` has released the 0806 handle and
holds only 0800. The reply is undeliverable. Answer at 2 seconds and the entry
is still fresh.

Measured on hardware 2026-09-02, four minutes of idle polling each way:

| hold | polls | unacked | |
|---|---|---|---|
| 8s | 24 | 4 | 17% |
| **2s** | **30** | **1** | **3.3%** |

The 3.3% that remains is just this WiFi link -- it matches the loss measured
with 30 pings -- so the long hold had been causing **five sixths of the
failures**, all of them self-inflicted.

The cost is a poll every ~6 seconds instead of ~11. That is nothing on a LAN,
and a wired box both loses less to begin with and pays less for the shorter
hold. `DOSD_POLL_HOLD` overrides it if some link ever makes the chatter matter
more than the misses.

**This is the third time on this machine that a plausible cause was accepted
without checking that the fix took effect** -- the others being `HTGET -quiet`
and `dos/live/AI.BAT` having drifted from the box. The pattern to distrust is a
change that produces no measurable difference: it is far likelier to be
unapplied than ineffective.

**`CHOICE` echoes the answer it picks, and `/N` does not stop it.** `/N` hides
the `[Q,Y]?` prompt only; on every timeout CHOICE still printed a bare `Y`, so
an outage cost a line per retry anyway -- most of what putting the `[offline]`
notice behind a flag was meant to fix. It needs `> NUL` as well. CHOICE reads
the keyboard directly rather than through stdin, so redirecting its output does
not stop `Q` from working.

The flag is created with `ECHO . >` and not `COPY C:\AGENT\EXIT0.COM`, because
`EXIT0.COM` is fetched by the first job -- on a box that has not run one yet
there would be nothing to copy, so the flag would never appear and the message
would be back every five seconds. It is deleted at agent startup too: a flag
left by the outage that was in progress when the box went down would otherwise
silence the first notice after a reboot.

The address lines come from `UGET -INFO`, not from `FIND` on the config file.
`FIND` printed a filename header as well as the address -- two lines, one of
them noise -- and it could only ever read mTCP's config, never the bridge's
own. `-INFO` reports whichever file was actually used, which matters now that
there are two candidates. Its label field is 12 wide to match the banner: two
lines printed by different programs under one heading look accidental unless
their colons line up.

`CHOICE /N` in the `:OFFLINE` branch hides CHOICE's own `[Q,Y]?` prompt -- the
line above it already says which keys work.

**The banner still scrolls once a dozen or so jobs have run.** That is the
trade for showing job detail at all, and it is the right way round: an idle box
keeps its banner indefinitely, and a busy one shows what it is busy with.

## The box was never freezing. It was still retrying.

**Settled on hardware 2026-09-03, by leaving it alone and watching.** A file
transfer stalled at 16:32:53 and the box stopped polling. Nobody touched it:

```
16:32:53  box goes quiet, mid-transfer
16:37:38  box polling again        <- unattended, 4m 45s
```

It is not a hang. `UGET` hits a stalled transfer, tears the flow down and
rebuilds it -- new handle, new ARP, new local port, re-request from the byte
it reached -- and keeps doing that. Throughout, the agent loop is running and
the machine is healthy; it simply is not polling, and from Windows that is
indistinguishable from a wedge.

**Which is how it got misdiagnosed three times in one day.** Two of those
ended in a power cut to a machine that was going to come back on its own.
`dospower`'s own guard refusing a second cycle was more right than the reason
given for it at the time.

**The predicted number was wrong too, and by a lot.** `RESTART_AFTER` is 3
timeouts of ~2s and `MAX_RESTARTS` is 250, which reads as 25 minutes of
grinding -- so 25 minutes is what these notes said. Measured: 4m 45s. The full
budget is never walked; some earlier limit ends it. **Arithmetic over a
constant is not a measurement**, and the two differ here by 5x.

The 43- and 48-minute silences earlier that day were never verified at all --
they were power-cycled before anyone waited. They may well have been the same
self-recovering stall.

### The fix: budget restarts against progress, not against a count

`MAX_RESTARTS = 250` is right for what it was sized for. A 5 MB file over a
link that genuinely stalls every 45 KB needs about 110 restarts, and every one
of them moves data. It is useless as a stopping rule for a peer that is *not
there*, because a count cannot tell "slow and lossy" from "gone".

So `tftp.pas` now counts restarts that achieved **nothing**:

```pascal
if TftpBytes = DeadMark then Inc(DeadRuns) else DeadRuns := 0;
DeadMark := TftpBytes;
if DeadRuns > DEAD_RESTARTS then      { 3 }
begin
  TftpErr := 'no answer from the server';
  Break;
end;
```

A restart that recovers even one block is the fault the mechanism exists for
and costs nothing from this budget. Three in a row that move zero bytes is a
dead peer, which is about twenty seconds -- after which the transfer fails,
the agent's `:OFFLINE` branch takes over, and **the box keeps polling**. Both
directions, because the stall happens sending as well as receiving.

**This treats the consequence, not the cause.** The underlying mid-transfer
stall -- frames stopping for this card while broadcasts keep arriving -- is
still unexplained and still there. It should now cost seconds rather than
looking like a dead machine.

### Verified on hardware, both halves

The two cases are opposites and both had to be checked, because a budget that
ends dead flows too eagerly would break the large transfers that resume-on-
stall exists for.

**A stall that recovers -- the regression risk.** 1 MB over the WiFi link:

```
16:53:32  tftp: resuming local/BIG1M.BIN at byte 134400
16:53:44  tftp: sent local/BIG1M.BIN ... FAILED
16:54:17  tftp: sent local/BIG1M.BIN (914176 bytes)
          62s, 749 blocks of 1400, 5 resends, rc 0
          CRC-32 998E4325 on the box, 998E4325 on Windows
```

It stalled, rebuilt the flow, finished byte-exact. Restarts that move data
still cost nothing from the new budget.

**A peer that goes away -- the case the budget is for.** `dosd` killed 14
seconds into a 1 MB transfer and kept dead for a full minute:

```
17:13:29  shutdown requested -- bye
          ...61 seconds with no server at all...
17:14:30  dosd listening
17:14:32  job RRQ from the box          <- polling 2s later
```

Two seconds. The box had already given up, printed its failure and gone back
to the `:OFFLINE` retry, so it caught the first poll the moment there was
anything to answer it. `C:\AGENT\PHASE.LOG` confirms the job ended properly
rather than being abandoned:

```
8ff0 cmd0 C:\TOOLS\UGET.EXE
8ff0 cmds done                          <- UGET returned
8ff0 send
8ff0 sent                               <- and the result was delivered
```

Against 4m 45s of silence for the same event before the fix.

**Two earlier attempts at this test were spoiled and are worth remembering.**
The first measured the wrong thing -- it timed from when *its own* daemon
returned, by which point the box had been polling for half a minute, so it
reported 9s for something that had taken 16. The second was contaminated by a
second `dosd` starting mid-window: the server was only absent 13 seconds,
which is inside the budget, so the run could not have proved what it appeared
to. On Windows two daemons will both bind the same ports and delivery becomes
a coin flip, so "is exactly one running?" is worth checking before believing
any measurement that involves restarting it.

### The stall underneath is still unexplained, and it defeats instrumentation

The retry grind above is fixed. The thing that *causes* a stall is not, and it
is worth recording how many attempts to measure it have now failed, because
every one of them produced a plausible number that meant nothing.

`CLAUDE.md` already carried four dead hypotheses -- ARP expiry, the server
deadlock, the receive handle wedging, the card's address filter -- each built,
measured and removed. Three more failed on 2026-09-03:

* **Sniffing it is not available.** The obvious move is `PKTCAP` on the box:
  watch whether the server's blocks reach the wire. It cannot work. Capturing
  needs an `access_type` handle for the same ethertype the transfer is using,
  which the driver may refuse, and capturing `ALL` takes frames away from the
  transfer being watched. The observer changes the observed. If this is ever
  worth doing properly it needs a *second* machine on the same segment.
* **A window that included what it was meant to exclude.** `tftp.pas` was made
  to sample the receiver's counters at each flow rebuild, giving "what arrived
  during the silence". The mark was taken at transfer *start*, so the first
  stall's window spanned the whole successful transfer before it -- and duly
  reported ~100 frames as having arrived during total silence. They were the
  good blocks.
* **A guard that could never fire.** The fix for that tested `Tries = 0` at
  the top of the stall branch. `Inc(Tries)` runs *before* that branch, so the
  condition was never true and the mark silently kept its transfer-start
  value. Same artifact, second time, from the code written to remove it.

**What caught both was a contradiction, not a review.** The counters read
`448 seen, 19 not ours`, implying 429 frames matched our IP and port during a
timeout -- impossible, because a match makes `NetUdpRecv` return instead of
timing out. A number that disproves itself is the only reason either bug was
found. Build the contradiction test into the reading, not the code review.

**Know what the counters mean before quoting them.** `NetRxFrames` counts
*every* frame pulled out of the receive buffer, ours or not; `NetRxWrong`
counts the ones that did not match. "Ours" is the difference. The first
version of the report labelled `NetRxFrames` as "ours", which is what made
the impossibility legible -- an accident that happened to help.

### A burst of stalls on 2026-09-04: it was the EMS card's jumpers

Worth reading as a whole, because the wrong answer was reached twice on the
way and the second one was reached *by a test that looked clean*.

The rate jumped sharply: several stalls in an afternoon against roughly one a
day before, all with the same signature -- powered at ~36 W, no polling, no
self-recovery, back immediately on a power cycle.

**First theory: the newly fitted 2 MB Lo-tech ISA EMS card.** An EMS page
frame is 64 KB of upper memory and the PicoMEM lives up there too, so an
overlap would give exactly this -- fine until something touches it.

**The test that appeared to disprove it.** The PicoMEM's memory expansions
were turned off and the box rebooted, which removed expanded memory entirely
(`MEM` reported none again, conventional back from 540 KB to 545 KB). It
stalled on the very next batch. That looked conclusive and was not:
**disabling a DRIVER does not stop a misjumpered ISA card from decoding its
address range.** The hardware still answers on whatever the jumpers select,
whether or not anything is driving it. The card was never actually out of the
picture.

**The second theory, from a real correlation.** Every stall had happened
during a run of `dosrun`s, and each `dosrun` pushes the binary over TFTP;
`RAYCAST.EXE` had grown to 57 KB, past the ~50 KB mark this file already
records as where transfers start failing, and its `dosctl upgrade` had failed
CRC twice the same day. Deploying once and iterating with `dosexec` -- which
transfers nothing -- gave **9 consecutive clean runs** where `dosrun` stalled
within a few. Consistent, reproducible, and still not the cause.

**The actual fix was the jumpers.** They were wrong from the moment the card
went in. Corrected, with the PicoMEM's memory handling left off and EMS
re-enabled on the dedicated card:

| | |
|---|---|
| before | stalled within 2-5 `dosrun`s |
| after | **11 consecutive `dosrun`s, no stall** |

including three `FLAT` runs, which had twice taken the box down.

Three things to take from it:

* **A disproof is only as good as its isolation.** Turning off the driver
  felt like removing the card and was not remotely the same thing. When
  ruling hardware out, rule out the *hardware*.
* **A strong correlation can be a symptom.** The transfer-size link was real
  and reproducible -- large transfers were simply the thing that reliably
  touched whatever the conflict broke. It would have been easy to stop there
  and write the wrong cause into these notes with measurements attached.
* **The `dosexec` habit is worth keeping anyway.** For repeated testing of a
  binary over ~50 KB, `dosdeploy` it once and iterate with `dosexec` on
  `C:\TOOLS\`. Nothing crosses the wire per run, so it is faster as well as
  one less thing that can fail. Use `dosrun` when the binary has changed.

**There is also a second failure, distinct from the grind.** On 2026-09-03 the
box went quiet for six minutes having issued **no requests at all**:

```
20:45:33  job RRQ from 192.168.1.20:20552 -- holding
20:45:45  idle batch -> 192.168.1.20:20552  NO ACK
          ...six minutes, no RRQ of any kind...
```

That cannot be the retry grind: a job poll runs with `MaxRq = 0` and gives up
on the first miss by design. Something stops the box *asking*. It needed a
power cycle. Do not fold this into the grind -- they have different
signatures and only one of them is fixed.

The corrected probe is deployed and will report on the next stall it sees, at
no cost. Treat whatever it says as a hypothesis until it survives the same
contradiction test.

## Finding out where a freeze happened: `C:\AGENT\PHASE.LOG`

The box has frozen repeatedly with nothing to show for it. The console's last
line is whatever finished BEFORE the hang, so all it ever says is "not there
yet", and the daemon's log only records that the box stopped answering.

Every generated batch now drops breadcrumbs as it goes, the same trick
`dosdrv` uses to survive a driver that wedges the machine:

```
ECHO ab12 fetch RAYCAST.EXE >> C:\AGENT\PHASE.LOG
C:\TOOLS\UGET.EXE %UPHOST% starter/RAYCAST.EXE C:\WORK\RAYCAST.EXE
ECHO ab12 got RAYCAST.EXE   >> C:\AGENT\PHASE.LOG
ECHO ab12 run RAYCAST.EXE   >> C:\AGENT\PHASE.LOG
C:\WORK\RAYCAST.EXE > C:\WORK\OUT.TXT
ECHO ab12 ran RAYCAST.EXE   >> C:\AGENT\PHASE.LOG
```

Read it after a freeze with:

```
dosexec "TYPE C:\AGENT\PHASE.LOG"      or  dospull C:\AGENT\PHASE.LOG
dosexec "DEL C:\AGENT\PHASE.LOG"       start a clean run
```

**How to read the last line:**

| last entry | where it froze |
|---|---|
| `fetch X` with no `got X` | inside the transfer -- UGET, our own stack |
| `got X` with no `run X` | between them, which is only `IF EXIST`/`DEL` |
| `run X` with no `ran X` | inside the program itself |
| `ran X` for the previous job, nothing since | in the POLL -- also UGET, but no batch was running to leave a mark |

That last row is the useful accident: a poll hang leaves *no* new entry at all,
so the absence of one is itself the signal. It means the poll case needs no
change to `AI.BAT` and therefore no reboot -- which matters, because with the
CMOS battery dead a reboot now stops at an F1 prompt and needs hands.

Three things about the design:

* **APPEND, not overwrite.** The obvious version writes one word to a file and
  reads it back after the reboot, and it cannot work: reading the file needs a
  job, and that job's own batch overwrites the marker before the pull runs. An
  append-only log keeps the frozen job's last line underneath whatever the
  recovery job adds.
* **`ECHO` opens, writes and closes**, so each line is committed before the
  next command starts. A buffered write would be lost in exactly the case this
  exists for.
* **`DOSD_PHASE=0` turns it off.** It costs a file open/write/close per phase,
  and if the disk I/O ever becomes a suspect itself, that has to be removable
  without redeploying the agent.

Batches are generated per job, so this needs a **dosd restart** and nothing on
the box.

## The CMOS battery is dead, and it breaks power-cycle recovery

**Found 2026-09-03.** The box's clock reads `01-01-80 12:08a` a few minutes
after boot, and POST stops with **"Press F1 to continue"** waiting for a
keypress.

**It is probably NOT a flat battery, and the first version of this section
said it was.** Running the PS/2 utility at the keyboard showed the RTC holding
`09-03-2056` -- the correct month and day, today's, with only the year wrong.
A dead battery loses everything; a chip that keeps the date and drifts the
year is one that still has power. What fits is a corrupt CMOS *configuration*
record: that is what halts POST, and what makes the BIOS hand DOS nothing
usable so DOS falls back to `01-01-80` while the RTC itself still knows the
day.

It is also the same fault recorded on 2026-08-31 -- "month, day, hour and
minute all correct, only the year wrong" -- drifted further. On a PS/2 the
repair is *Set Configuration* from the Reference Diskette, not a CR2032.

The POST code distinguishes them and costs nothing to read: **161** is the
battery, **162** a configuration/checksum error, **163** time and date not
set.

This file said on 2026-08-31 that "the CMOS battery is fine and the year had
simply never been set", on the evidence that a *warm* reboot preserved the
time. That test could not distinguish the two: a warm reboot never re-reads
CMOS. Only a power cut does, and the first one was months later.

**So the smart plug cannot currently recover this box unattended**, which is
the one thing it exists for. A hard cut runs POST, POST halts at F1, and the
machine sits there drawing ~37 W and never polling -- indistinguishable over
the bridge from the hang it was cutting power to fix. Twice on 2026-09-03 a
cycle was scored as "box did not come back" when it was really sitting at the
prompt.

Until the battery is replaced:

* Read a failed recovery as "check the screen", not "the machine is dead".
* `dospower status` still separates *off* from *powered*, which is the half
  that still works: ~37 W and no polling now means POST, not a wedge.
* A warm `dosreboot` does not trigger it. Prefer it over a power cut whenever
  the box is still answering.

Note this is entirely separate from the mid-run freezes. Those happen on a
machine that has already booted and is polling, and nothing about POST
explains them.

## Seeing the box for real: video capture

Optional, off unless configured, and the first thing here that does not look
at the DOS box **through DOS**. **`capture.md` is the full write-up** --
setup, watching it live, the raw `ffplay` command, and troubleshooting. What
follows is the part worth knowing without going there.

```
doscap devices                what capture hardware is on this machine
doscap modes                  what the configured device can produce
doscap status                 device present? is a picture arriving?
doscap shot [FILE]            one still
doscap rec SECS [FILE]        record. --audio, --shots N
doscap burst N [--every S]    a series of stills
doscap still REC SECS [FILE]  pull a frame out of a recording
```

Verified on hardware 2026-09-05 against a MacroSilicon-class USB 3.0 HDMI
capture stick (`VID_345F&PID_2131`), at **1600x1200 yuyv422 60 fps, 4:3**.

**Everything else in this bridge is the machine reporting on itself.**
`WriteLn` goes through captured stdout, `SCRAPE` reads the text buffer back,
`VSHOT` reads mode 13h back, and the raycaster prints its own ASCII thumbnail
because nothing else could photograph an unchained mode. All of that can only
show what somebody wrote code to show, and only while the box is still
running. A capture card sees what a monitor sees: POST, the **F1 prompt from
the dead CMOS**, whichever way the video card lost the boot lottery, a frozen
screen with the last line still on it, and every graphical demo as it renders
rather than as its own thumbnail describes it.

**It proved itself before it was finished.** During the build `dosctl status`
said `STALE, last poll 2518s ago (hung? powered off?)` -- and it cannot do
better, because the thing that would have to answer is the thing that is not
running. One frame showed the box sitting in **MS-DOS EDIT with a dialog
open**: somebody had been at the keyboard. Not hung, not off, and a power
cycle would have been exactly the wrong response. That is the ambiguity this
file records being resolved the wrong way three times in one day on
2026-09-03, and it is now one command.

### It is a second opinion, not a replacement

`SCRAPE` and `VSHOT` read the framebuffer and give exact bytes. This gives
photons, after a VGA-to-HDMI converter has scaled them and a capture chip has
subsampled the colour. Text is legible and geometry is faithful, but **do not
CRC a captured frame or read exact pixel values out of one.** Use it for what
is on the screen, and the existing tools for what is exactly in the buffer.

### The frame rate is not an instrument

Worth stating plainly in a project that measures frame rates this carefully.
The box's text and mode 13h output is **70 Hz**, the capture is **60 Hz**, and
there is a scaler in between doing its own thing. A recording therefore
duplicates and drops frames against the original **by construction**. It shows
what was drawn; it cannot say how fast. `RAYCAST`'s own reported fps and
`modex.pas`'s `FlipLate` remain the measurements.

### Four things measured, none of them guessed

* **The device is EXCLUSIVE.** A second capture while one is running fails
  with "device already in use" -- promptly, cleanly, and *not* as a hang,
  which is the failure this project actually fears. So `rec --shots N`
  records first and extracts the stills from the finished file afterwards,
  rather than trying to hold the device open twice. `doscap still` does the
  same thing on demand.
* **`rtbufsize` is a correctness setting, not a tuning knob.** ffmpeg's
  default real-time buffer is about 3 MB and one 1600x1200 yuyv422 frame is
  **3.84 MB** -- less than a single frame -- so it drops frames before it has
  a whole one, and says so. It is 512M here. Raise it with the resolution,
  not with the length of the recording.
* **x264 `ultrafast` keeps up and `veryfast` does not.** Measured over 8
  seconds at 1600x1200x60: ultrafast gave **481 frames, zero drops, 3.1 MB**;
  veryfast dropped frames. MJPEG stream-copy also drops nothing and is
  **80 MB for the same 8 seconds** -- 26x the size, for a codec that
  recompresses text badly. If a capture ever drops frames, make the preset
  faster before making anything else smaller.
* **The first frame can be stale**, so a snapshot asks for `warmup_frames`
  and keeps the last. Six frames costs a tenth of a second.

### HDMI carries the AdLib but NOT the PC speaker

`rec --audio` records it, and `doscap live` plays it by default.

**`live` runs audio and video as TWO SEPARATE PROCESSES**, and that is the
whole design rather than an implementation detail. One ffplay given both
streams has to reconcile two unrelated clocks -- the stick's video and audio
clocks free-run independently -- and either choice is bad: audio as master
makes the real-time buffer climb without bound (63% -> 87% and rising), and
`-sync video` bounds it but continuously resamples audio to chase video,
which is audibly choppy. Neither is a buffering problem: a quarter of the
pixels, half the frame rate, `rtbufsize` from 32M to 512M and
`-af aresample=async` all changed nothing. **A throughput problem responds to
less work; a clock problem does not.** The split version is confirmed good
by ear; note every rejected variant above was also silent on screen, so the
absence of errors proved nothing.

The video and audio captures are *different* DirectShow devices, so two
processes can hold them at once. Audio alone has nothing to sync to and plays
samples as they arrive -- the same condition that makes a `rec --audio` file
clean. The cost is A/V sync between the two, which is worth nothing for
watching a DOS box.

The audio player runs `-nodisp`, so it has **no window**: its pid goes in
`capture/live-audio.pid` and the next run reaps it, `tasklist`-checked
because pids get reused. The obvious assumption -- that this gets you the box's sound
-- is half wrong, and which half had to be measured: the PC speaker is a
buzzer on the motherboard while the AdLib feeds a sound card, and only one of
them has a path into the converter's audio input.

| playing | RMS | Peak |
|---|---|---|
| nothing, box idle | -65.3 dB | -77.4 dB |
| **`MOZART`, PC speaker** | **-64.9 dB** | **-77.3 dB** |
| `RAYCAST`, AdLib/OPL2 | **-27.7 dB** | -40.8 dB |

`MOZART` is **0.5 dB from silence** -- the speaker does not reach the capture
at all. The AdLib is **37 dB above the floor**. So `AMOZART` and `RAYCAST`'s
music are checkable from another machine for the first time, and `MOZART`,
`BEEP` and `RAYCAST SPKR` are not: for those the speaker-gate PASS in the
program's own output stays the only evidence.

**The wiring is why**, and it is deliberate here: the sound card's line-out
is patched into the converter's audio input, so what the card plays is
embedded into the HDMI stream. The speaker is not on that path and no cable
puts it there without a mixer. A rig with nothing patched in captures no
sound at all, so this is **this machine's wiring** rather than a property of
capture sticks.

**Confirmed by ear, not just by meter.** A `RAYCAST` recording was played
back and the OPL2 music is clean, so the path is verified end to end. That
step needed a person -- 37 dB above the floor is equally consistent with a
tune and with hum, and no measurement here separates them.

### Configuration, and why it is required rather than detected

A JSON file, `capture.json`, beside `capture.py`. Same rule as `power.json`:
`capture.example.json` ships, the live file never does, and its absence is
what keeps the feature off.

The reason differs though. A smart plug is off by default because cutting
mains power is dangerous. Capture is off by default because **the DirectShow
device name belongs to one machine** -- a shipped default would be wrong
everywhere else. `doscap devices` prints the block to paste, and it works
with no config at all, because it is what you need in order to write one.

**It offers a device name only when there is exactly one.** This machine has
a webcam as well as the capture stick, and they are indistinguishable from
the enumeration; naming the webcam because it sorted first would be a
confident wrong answer rather than no answer.

`ffmpeg` is needed and the kit does not install it (`winget install
Gyan.FFmpeg`). A winget install is found automatically **even before the
shell has been restarted**, which is exactly the session somebody installs it
in and then tries to use it.

### Every failure path fails fast

Deliberate, and checked one at a time -- a capture that cannot open its
device must **fail, not wait**, because everything in this project that ever
needed hands on the keyboard looked like a hang first. `open_timeout` bounds
the device open, and every ffmpeg call runs under a hard timeout.

| | |
|---|---|
| device in use | names the conflict, suggests `doscap still`, rc 2 |
| device not found | lists the devices that *are* present, rc 1 |
| wrong name in the config | says to check it against `doscap devices`, rc 2 |
| not configured | says how to configure it, rc 1 |
| no ffmpeg | says how to install it |

### A recording survives a video mode change

This was expected to be the weak point and it is not. The box switches
between 720x400 text at 70 Hz and unchained mode X constantly, and each
switch makes the converter renegotiate -- so a 45-second recording was taken
across a whole `RAYCAST SECS 20` run, text to mode X and back.

**2701 frames in 45.016 seconds -- exactly 60 fps, zero drops.** The stream
never broke, the file is one continuous valid MP4, and the geometry never
changed.

What the switch *does* cost is about a second of black: the still sampled at
8.4s reads a perfectly uniform `rgb(0,0,0)`, `spread 0.0`, which is the
converter re-syncing. So a mode change costs **frames of content, not the
recording**. Anything sampling stills near one should expect a black frame,
which is exactly what `analyse` reports as `blank`.

Still unmeasured: whether a mode the converter cannot lock at all -- an SVGA
mode from `VMODES -t`, say -- behaves the same way or drops the stream.

## Recovering a box that cannot be reached: the smart plug

Optional, and off unless configured. Every unrecoverable failure this project
has hit ends the same way -- "needs hands on the keyboard" -- because the
thing that would have to act is the thing that is not running: a driver that
hangs before the network is up, a leaked packet driver handle, a PicoMEM card
that freezes during POST. A switched plug is the one lever left.

```
dospower                      state, power draw, and how many cycles are left
dospower on | off
dospower cycle [--force]      off, wait, on
dospower reset                forget the cycle history
```

Verified on hardware 2026-09-03 against a Shelly Plug US Gen4
(`S4PL-00116US`, fw 2.0.0): two real cuts, and the box was **polling again 21
and 29 seconds after power returned**, answering `dosexec "VER"` immediately
after.

**It is off by default and the installer cannot turn it on.** `power.py` and
`power.example.json` ship; `power.json` does not, and with no such file every
entry point returns "not configured" and no code can reach a relay. Same rule
as `MTCP.CFG`: a kit that arrived carrying somebody else's plug address, or
that overwrote a working local config on upgrade, would be worse than not
having the feature.

**The guards are the feature, not the on/off.** A recovery that can loop is
worse than none -- a box that will not come back for a reason power cannot
fix (a bad `AUTOEXEC.BAT`, a dead PSU, an unplugged aerial) would otherwise
be cut every couple of minutes, forever, with nobody watching.

| | |
|---|---|
| `min_interval_secs` | refuse a second cycle too soon. `--force` overrides |
| `max_cycles` / `window_secs` | hard ceiling. `--force` does **not** override |

That asymmetry is deliberate. Being asked twice in a minute is impatience,
and a human typing `--force` settles it. Hitting the ceiling means power has
already failed to fix this three times, and the honest conclusion is that it
is not going to -- so passing it needs somebody to think, not a flag.

Both limits are counted in `power.state` **on disk**, so they survive a
`dosctl` re-run in a loop or from a shell script. Holding them in memory
would make them trivially defeatable by the exact mistake they exist to
prevent.

`dosreboot` and `dosctl upgrade` use it automatically when `"auto": true`:
`wait_for_box` cuts power and waits again if the box never returns, bounded
by those same limits. The retry after a cut skips the wait-for-it-to-go-down
phase (`assume_gone`), because after a power cut the box is certainly down
and watching for that would burn the whole budget before the useful waiting
started.

**Read the power draw, not just the relay state.** `dospower` reports watts,
and that is the part worth having: it separates a machine that is *off* from
one that has power and has *hung*, and those need opposite responses. This
box idles at about 38 W.

```
plug    : shelly at 192.168.1.30
device  : S4PL-00116US gen4 fw 2.0.0
state   : ON  38.1 W  124 V
          drawing current, so the machine has power
cycles  : 0 in the last 60 min (max 3)
```

Other drivers exist and are **unverified** -- written from published local
APIs, never run against hardware, and they say so the first time they are
used: `shelly-gen1`, `tasmota`, `kasa` (not HTTP -- length-prefixed JSON over
TCP 9999 with an autokey XOR seeded at 171), `homeassistant` (worth having
because it covers hardware with no usable local API of its own), and `http`,
where you supply the URLs so an unsupported plug is a config entry rather
than a code change.

Two things learned wiring it up, both the same shape as failures recorded
elsewhere in this file:

* **Check the guards before printing the warning.** The "this is a HARD cut"
  banner printed first, so a *refused* attempt still told you the machine had
  just been power-cycled when nothing had happened.
* **`dosctl power cycle` silently ran `status`.** The action was read from
  `args.rest`, which is always empty: the parser only ever sees the first
  passthru word, and the rest lives in `tail`. Every action read as the
  default. The same class of bug as `--quiet` falling through into the
  command tail.

## Hard constraints — these are not style preferences

**Exit codes must be ≤ 20.** DOS 6.22 cannot read `ERRORLEVEL` into a variable,
so `dosd.py` generates an `IF ERRORLEVEL n` ladder that stops at 20. A program
returning 47 will report as 20. `Tester.Finish` already caps at this.

**A DOS critical error is a remote hang.** Anything that touches a drive with
no media — `INT 21h AH=36h` on an empty floppy is the one that caught us — puts
"Abort, Retry, Fail?" on the console and blocks until somebody presses a key.
Over the bridge that is indistinguishable from a wedged machine, and it needs
physical hands to clear. Never probe A: or B: speculatively; `hwinfo` starts its
drive scan at C: for exactly this reason. The general fix, if a tool ever really
must touch removable media, is an `INT 24h` handler that returns 3 (fail)
instead of prompting.

Symptom to recognise: output truncated mid-line with `##RC=` glued to the end.
That is DOS never flushing its buffer because the program was aborted at the
prompt, not a crash.

**Never move binaries with `TYPE` or a bare `NC`.** Use `dospull`. DOS `TYPE`
stops dead at the first 0x1A (Ctrl-Z), and `NC` without `-bin` opens stdin in
text mode and silently eats every 0x0D and 0x1A — a 27298-byte EXE came back as
27258, corrupt but plausible-looking. `dospull` uses `NC -bin` into a dedicated
raw port (8082) that does no decoding at all; that `-bin` is load-bearing.
`dosexec "TYPE ..."` is fine for text files and nothing else.

**A job that reboots cannot report back.** `dosexec "REBOOT.COM"` runs the
reboot partway through `JOB.BAT`, so the machine is gone before the `NC` that
would send the result. The old behaviour was a silent 120-second wait ending in
"DOS box may be hung", which blames the box for doing exactly what it was told.
`dosctl exec` now spots `REBOOT`/`COLDBOOT` in the command list, says so, and
switches to watching the box drop and return instead of waiting for a result.
It also warns that any commands *after* the reboot will never run.

Use `dosreboot` to reboot, or `dosrun --reboot` to run something and then
reboot. `dosdrv` already does this correctly -- its batch ends with
`COLDBOOT.COM` and reports through the crash guard on the next boot instead.

**Don't trust `dosexec`'s exit code for internal commands.** DOS internal
commands (`ECHO`, `VER`, `DIR`, `IF`, `DEL`, `TYPE`) never set `ERRORLEVEL`.
`dosd` runs a generated `EXIT0.COM` before your commands so the ladder reads a
known 0 instead of a stale value, but a *failing* internal command still can't
report failure — `DIR C:\NOSUCH` exits 0. Assert on stdout for those. The exit
code is only meaningful when the last command is an external program. `dosrun`
is unaffected: the program it runs sets a real `ERRORLEVEL`.

**A missing program was the worst version of this, and it is now caught.**
`dosexec "C:\BAD.EXE"` used to return **no output and rc 0** — a confident
success for a program that never ran. Two things conspire: COMMAND.COM writes
`Bad command or file name` to a console 6.22 cannot redirect (there is no
stderr redirection at all), and a bad command leaves `ERRORLEVEL` untouched,
which `EXIT0.COM` has just forced to a clean 0. The box says so on its own
screen and has no way to tell anyone.

So `dosd` now emits a guard before any command that names a program by an
explicit path:

```
IF NOT EXIST C:\BAD.EXE ECHO ##NOEXEC=C:\BAD.EXE >> C:\WORK\OUT.TXT
```

`dosctl` lifts that marker out of the captured output, prints the program that
was missing, and exits **127**.

**The check is deliberately narrow: an explicit path AND an executable
extension.** Both halves are load-bearing, and widening either would make it
worse than useless:

* `IF EXIST FOO.EXE` searches only the current directory, so checking a
  PATH-resolved name would report every working tool as missing. A false
  "not found" on a command that runs is worse than the silence it replaces.
* `C:\TOOLS\FPU` has no extension, and COMMAND.COM would happily find
  `FPU.EXE` for it. Flagging that would be wrong too.

Narrow still covers the case that actually bites, because `C:\TOOLS` is not on
the box's PATH: the documented way to call every tool in the kit is by full
path, so a typo in one of those is exactly what used to vanish.

For everything else — a bare name resolved through PATH — nothing on the DOS
side can tell us. `dosctl` falls back to saying so: a job that returns empty
output with rc 0, where some command could have been a program, prints a note
that this is also what a missing program looks like. It does not change the
exit code, because a job made of `DEL` and `SET` is legitimately silent.

**Output must go through DOS.** `WriteLn` is captured; direct writes to B800
video memory are not. A program that only draws to the screen returns an empty
log. If you write screen code, make it also `WriteLn` what it did.

**8.3 filenames.** `dosctl` rejects long names rather than letting DOS silently
truncate them.

**A `>` immediately followed by `=` is a syntax error, even inside a `REM`.**
COMMAND.COM parses redirection before it works out that the command is a
comment, and `>=` is a redirect with no filename. Every time the line is
reached it prints `Syntax error` on the console. Nothing is created and
nothing breaks -- `REM` never opens the file -- but it is noise on a screen
whose whole job is to be readable, and it appears at exactly the moments
somebody is standing there reading it.

Verified on hardware 2026-09-03, one form at a time:

| in a `REM` line | |
|---|---|
| `-` then `>` (an arrow) | fine |
| `=` then `>` | fine |
| `>` then `=` | **`Syntax error`** |
| `> NUL` | fine |

It arrived in a comment explaining the `ERRORLEVEL` fix above -- the phrase
"which is >= 20" -- so the agent printed a syntax error on every failed poll
while working perfectly. Write "20 or more" in batch comments. The first
attempt at the fix reintroduced it in the sentence describing the rule, which
is why the check that catches it is a grep for `>=` on `REM` lines and not a
careful read.

**A chained `IF` silently drops an external command.** COMMAND.COM 6.22 runs
`IF cond IF cond CMD` correctly when `CMD` is *internal* (`ECHO`, `GOTO`,
`DEL`), and does **nothing at all** when it is *external*. No error, no output.
This cost a debugging round: `IF NOT "%MTCPCFG%"=="" IF EXIST %MTCPCFG% FIND
"IPADDR" %MTCPCFG%` printed nothing and read as a missing config file, while
the same `FIND` behind a single `IF` worked. One `IF` per line; branch with
`GOTO` when two conditions are needed.

**mTCP tools consume queued keystrokes.** `HTGET` and `NC` poll the keyboard so
ESC or Ctrl-Break can abort a transfer, and they eat whatever is waiting. Never
build a control mechanism on `INT 16h` buffered input in a loop that also does
network I/O -- see the ScrollLock section above for what to do instead.

**Never write to CONFIG.SYS.** This is the important one. A bad driver in
`CONFIG.SYS` hangs the machine before `AUTOEXEC.BAT` runs, which means no code
on the box can undo it and power-cycling just re-runs the same bad config — it
needs a boot floppy and physical hands. `dosdrv` therefore stages drivers into
`C:\AGENT\PEND.BAT` and loads them with `DEVLOAD` from `AUTOEXEC.BAT`, after the
network is already up, behind a `TRYING.FLG` guard. If you are ever tempted to
edit `CONFIG.SYS` to make something work, stop and raise it instead.

**Avoid SysUtils in Pascal.** `IntToStr` and friends link a lot of dead weight
into a 16-bit real-mode binary. `Tester.Note` has a `LongInt` overload for this
reason.

## Reserved exit codes

| | |
|---|---|
| 253 | driver wedged the machine; it was skipped on the recovery boot |
| 254 | file download to the DOS box failed |
| 127 | a command named a program that is not on the DOS box |
| 124 | timed out waiting for the DOS box (probably hung) |

127 is the conventional shell code for "command not found" and cannot collide
with a DOS program's own status, because the `IF ERRORLEVEL` ladder stops at
20.

## Toolchain

Free Pascal 3.2.2 cross-compiling to `i8086-msdos`. The **i386/win32** native
compiler is the prerequisite for the cross package, not the Win64 one.

```
fpc -Tmsdos -Pi8086 -WmLarge -FEbuild -FUbuild <name>.pas
```

Memory model is `-WmLarge` by default. `-WmSmall` if the binary is tight and
data fits in 64K.

### Assembling on the DOS box itself

Use **`E:\MNASMFIX.COM`** for `.ASM` files. It is a build of `mininasm`, a
NASM-compatible assembler that runs in **real mode**:

```
E:\MNASMFIX.COM -f bin C:\WORK\FILE.ASM -o C:\WORK\FILE.COM
```

Only `-f bin` and `-f com` are supported — no `obj`, so no linker step. That is
fine for `.COM` programs and for `.SYS` device drivers, which are flat binary
images anyway. It defines `__MININASM__`, and supports the usual NASM
preprocessor (`%INCLUDE`, `%DEFINE`, `%IFDEF`, `TIMES`, `STRICT`).

**Do not use `C:\NASM\NASM.EXE`.** It is a 32-bit DJGPP build that needs
`CWSDPMI`, and this box is 8086-class with no protected mode at all, so it cannot
run on this machine. That is what `MNASMFIX.COM` exists to work around.

Verified end to end on 2026-08-29: a 281-byte `.ASM` deployed with `dosdeploy`,
assembled to a 40-byte `.COM`, ran, and returned its output and errorlevel 3.

### Borland Pascal 7 / TASM

`C:\BP\BIN` holds a full BP7 install, but it is **not** all real-mode native.
Exercised from the bridge on 2026-08-30:

| | |
|---|---|
| `TPC.EXE` | **works.** Turbo Pascal 7.0 command-line compiler, real mode |
| `TASM.EXE` | **works.** Turbo Assembler 3.2, real mode, writes to stdout |
| `BPC.EXE` | **no** — `Stub error (2001): needs at least 286` |
| `TLINK.EXE` | **no** — `Failed to locate DPMI server (DPMI16BI.OVL)` |
| `BP.EXE` | never run it over the bridge: full-screen IDE, waits for a key |

So on an 8086-class box the usable pair is `TPC` (which has its own built-in
linker and needs no TLINK) and `TASM`. `BPC` and `TLINK` are DPMI applications
and are simply unavailable here.

Verified end to end: a `.PAS` deployed with `dosdeploy`, compiled with
`C:\BP\BIN\TPC.EXE`, run, output captured, `Halt(3)` came back as errorlevel 3.

Two gotchas worth knowing:

* **`BPC` writes its errors straight to video memory**, so a failed `BPC` run
  returns completely empty output and rc=0 over the bridge — it looks like a
  command that did nothing. That is how the 286 stub error stayed invisible
  until `SCRAPE` was run in the same job. `TPC` and `TASM` both use stdout and
  capture normally.
* **Never `uses Crt` in a program driven over the bridge.** Crt's unit
  initialisation replaces the standard Output driver with one that writes
  straight to video memory, so every `WriteLn` after it stops being captured
  and the job returns empty. If you need the speaker, program ports 43h/42h/61h
  directly the way `starter/beep.pas` does, and take timing from the BIOS tick
  counter at `0040:006C` rather than Crt's `Delay` -- which also sidesteps the
  Runtime Error 200 calibration bug. Verified working in `C:\BPDEMOS\BPHELLO.PAS`.
* `TPC` prints a progress counter that relies on carriage returns overwriting
  in place. Redirected to a file it accumulates, so a clean compile looks like
  `BPHELLO.PAS(1)BPHELLO.PAS(1)BPHELLO.PAS(9)BPHELLO.PAS(9)`. That is normal
  output, not an error.

`TPC.CFG` and `BPC.CFG` both point `/U` at `C:\BP\UNITS`, which is **empty** on
this box; the real `TURBO.TPL` lives in `C:\BP\BIN` and the compiler finds it
next to itself, so a plain program compiles regardless. Anything needing `Crt`,
`Dos` or `Graph` may need `/UC:\BP\BIN` adding.

Code size is the reason to care: `TPC` built a 2,320-byte hello, against
25,880 bytes for the same thing cross-compiled with FPC.

## Testing without hardware

`selftest.py` runs `dosd.py`, a simulated DOS box, and the CLI end to end. Use
it to check changes to the bridge itself before involving the hardware. It does
not exercise the packet driver or any real hardware — a green selftest means the
Windows half is sane, nothing more. It needs 8069 and 8080-8082, so stop the
daemon first (`dosctl shutdown`).

**`simulate_dos.py` speaks the real transport**, and that is the part worth
protecting. It does actual TFTP against `dosd` — RRQ/WRQ, block numbering, ACKs
and the `blksize` negotiation — rather than pattern-matching the batch.

It did not always. The old version grepped each batch for `HTGET -o <url>` and
fetched over HTTP, so when the transport moved to UGET/UPUT **the regex simply
stopped matching and every run kept passing while transferring nothing at all**.
A test that cannot fail is worse than no test, because it is counted as
evidence: `selftest.py` was cited as "the Windows half is sane" during the very
session the 513-byte bug was loose.

Two properties keep it honest, and both are deliberate:

* **The payload crosses a block boundary.** It was 8 bytes (`"MZ fake"`), which
  is why nothing here could ever have caught a truncation at 513 — no transfer
  it made reached a second block. It is 3600 bytes now: three blocks at 1400,
  eight at 512.
* **A file is round-tripped and compared byte for byte.** Both directions are
  stop-and-wait with a short final block meaning "done", so an off-by-one in
  block sizing yields a file that is plausible, complete-looking and wrong.
  Only comparing against the source catches that, which is the same reason
  `dosctl upgrade` CRC-checks what it deployed.

The step numbering is a reminder rather than a rule: if you change the
transport, change the simulator in the same commit, and check the test still
*fails* when you break something on purpose.

## Layout

```
dosd.py           daemon: file serving, job queue, result intake
dosctl.py         the CLI; dos*.cmd are thin shims so it works from any directory
installer-src/    AUTHORED installer scripts only -- install.ps1, check.py,
                  the two makekit.py, makeinst.py. Nothing generated lives
                  here; the built installer goes to C:\DosBridgeInstaller.
                  buildno.txt is the build counter -- keep it in version
                  control, it is what makes "build 7" mean one thing.
                  The output's README.md is the install steps plus THIS
                  tree's README.md appended whole, assembled at build
                  time -- never hand-write a second copy of it
makeinst.cmd      build that installer from the current dev tree
dos/              files that live on the DOS box. Top level is a TEMPLATE for a
                  fresh install; dos/live/ mirrors THIS box; dos/archive/ is
                  superseded versions. See dos/README.md -- they are different
files/            dosd's serving root for /f/ fetches; holds staged programs and
                  the EXIT0.COM dosd writes on first run
projects/         YOUR work: one folder per project, made by `dosnew NAME`.
                  Staged under its own namespace so filenames cannot collide
starter/          FPC cross-compile setup, test harness, worked examples.
                  Reserved for the bridge's own tools -- not for new projects.
                  scroller.pas + modex.pas + music.pas live here rather than
                  in projects/ because they ship in the client kit: the
                  scroller is the demo that shows what the machine can do,
                  and SCROLLER.md is its write-up. kbd.pas is the INT 9
                  key-state unit RAYCAST KEYS uses; mkwalk.py generates the
                  timed-event scripts RAYCAST PLAY reads, and walk.txt is one
                  it made for the default seed. kinj.asm is the resident
                  keystroke injector and screen grabber, mkkeys.py compiles
                  its scripts, session.txt is a worked one. knet.asm is the
                  LIVE remote keyboard -- keys typed on Windows injected into
                  a running program -- and sendkeys.py is its Windows end
capture.md        how to run the capture: live preview, stills, recording
knet.md           how to use the live remote keyboard, and its four hazards
capture.py        optional video capture off a USB capture card, so the box's
                  REAL screen can be seen, recorded and photographed. Needs
                  ffmpeg and a capture.json; capture.example.json ships and
                  the live one never does, same rule as power.json
drvtest/          two throwaway drivers for exercising dosdrv's recovery path
selftest.py       end-to-end test of the Windows half
simulate_dos.py   fake DOS box, used by selftest
```

Each directory has its own README with detail. `README.md` at the root covers
setup and the failure modes worth knowing.

## Status

Verified on hardware 2026-09-01, the agent controls:

- `KEYHIT.COM` reads ScrollLock correctly (rc 1 on, rc 0 off) **and the
  reading survives a full `HTGET`** -- which is the whole reason it tests a
  flag bit rather than the keyboard buffer. A stuffed keystroke did not
  survive the same test.
- The boot banner renders every line, `IPADDR` included, with no
  `Out of environment space`.
- `TZ` set in `AI.BAT` removed mTCP's timestamp warning from every poll.
- The `STOP.FLG` mechanism `dosctl stop` uses: `COPY` creates it, the DOS
  side sees it, `DEL` clears it.
- End to end at the keyboard: reboot, ScrollLock, loop stopped, restarted.

Verified on hardware 2026-09-04, at the keyboard: ScrollLock stopped the
agent and **the agent cleared it on the way out, lamp included** -- so the
restart-stops-again trap is gone rather than merely documented. That was the
half of `SCRLOFF` that could not be checked over the bridge, because the
keyboard lamp is only visible to somebody standing at the machine.

Still not exercised: `dosctl stop` itself over the wire (same `:QUIT` path,
but the flag arrives from Windows rather than the keyboard), and
`selftest.py` against these changes -- it needs port 8080, so it has to run
with `dosd` stopped.

Verified on the real hardware: the job loop, both directions of transport
(including the mTCP `NC` return path), FPC cross-compilation of `hello` and
`sysinfo`, errorlevel propagation through `dosrun` and `dosexec`, and the
`AAD`-based NEC detection now in `starter/cpu.pas`, which reports
`CPU: NEC V20/V30` correctly on this box.

Verified on hardware 2026-08-30, after the coprocessor work:

- The rewritten CPU probe still identifies the V30 (FLAGS test routes it into
  the 8086-class branch, `AAD` then splits NEC from Intel). `Has186` comes back
  true and the `db`-encoded 186 immediate shift really does execute -- so the
  whole gating mechanism works end to end, not just in theory.
- The **shift-count test has still never run here**: `AAD` answers NEC first
  and short-circuits it. A 186/286/386 result remains unconfirmed.
- The FPU probe runs on a machine with **no** coprocessor without hanging,
  which was the main risk in it. `FPU.EXE` reports `none` and exits 1;
  `BENCH`'s four coprocessor rows skip cleanly.
- The BIOS equipment word disagrees with the probe on this box (see above).

`DEVLOAD.COM` is installed: v3.25 (FreeDOS, GPL2), copied from `E:\DEVLOAD.COM`
to `C:\DOS\DEVLOAD.COM`, which is on the box's PATH. Confirm with
`dosexec "IF EXIST C:\DOS\DEVLOAD.COM ECHO present"`. Its usage is
`DEVLOAD [switches] filename [params]`, which matches what `build_driver_batch`
generates. `dosdrv` is therefore unblocked.

The agent on the box was updated on 2026-08-29 to close the quiet-failure gap:

- `PEND.BAT` is now **served over HTTP** rather than assembled on the DOS side
  with `ECHO`. COMMAND.COM cannot escape a `>` inside an `ECHO`, so the old
  ECHO-built `PEND.BAT` could never contain a redirection — which is what was
  needed to capture DEVLOAD's output at all.
- It runs `DEVLOAD /V` and captures everything to `C:\AGENT\DRVOUT.TXT`, which
  `:TRYIT` now folds into the report. Previously that output went to a screen
  nobody was watching.
- With `--device NAME`, `PEND.BAT` also emits `##DEVICE` or `##DEVFAIL`, and
  `dosctl` turns `##DEVFAIL` into a non-zero exit.

`##RC=0` from `:TRYIT` still only means *the machine survived* — DEVLOAD exits 0
for a character device but returns the first assigned drive number for a block
device, so its errorlevel alone can't be trusted. `--device` is the reliable
check. The live agent is mirrored at `dos/live/AI.BAT`, the pre-change version
at `dos/archive/AI.pre-drvout.bat`, and `C:\AI\AI.BAK` on the box is a rollback
copy.

`dosdrv`'s **plumbing** is now verified on hardware: staging, `PEND.BAT`, the
`TRYING.FLG` guard, cold reboot, and the `##BOOTOK` report with `MEM /C` all
work, and `C:\AGENT` is left clean afterwards.

**But `drvtest/TESTDEV.SYS` is broken — it hangs the machine.** It is not the safe
driver its README claimed. Loaded via `dosdrv` it reported `##BOOTOK` while
silently failing to install (absent from `MEM /C`, `IF EXIST TESTDEV` false);
run directly as `DEVLOAD /V C:\WORK\TESTDEV.SYS` it wedged the machine and needed
a physical reset. Do not use it as a known-good driver. See `drvtest/README.md`.

This is the quiet-failure gap above, observed for real: `##BOOTOK` means "the
machine survived", not "the driver loaded". Always check `MEM /C` and
`IF EXIST <DEVICENAME>`.

`dosctl reboot` is verified: a warm reboot took the box down and back in 28
seconds, the drop-then-return detection worked, and the job loop was healthy
afterwards. `--cold` (full POST) is still untried.

Still not exercised: the `HANG.SYS` crash-recovery path. It deliberately wedges
the box and needs a physical power cycle — only run it when someone is at the
machine.
