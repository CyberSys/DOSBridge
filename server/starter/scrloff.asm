; scrloff.asm -- turn ScrollLock off, lamp included.
;
;   SCRLOFF        clear the ScrollLock state and put the keyboard LED out
;
; WHY THIS EXISTS
;
; ScrollLock is how the agent loop is stopped from the keyboard: AI.BAT runs
; KEYHIT.COM once per poll, which tests bit 4 of the BIOS keyboard flags at
; 0040:0017. That works because a flag bit survives being read, where a
; queued keystroke does not -- the network tools poll the keyboard themselves
; and eat anything waiting.
;
; The cost of using a latching flag is that it stays latched. The agent used
; to stop and leave ScrollLock ON, so restarting it -- by hand or by
; rebooting -- stopped it again on the very first poll. The banner said so in
; words, which is not the same as not having the problem.
;
; TWO HALVES, AND BOTH ARE NEEDED
;
; Clearing the BIOS flag is what actually un-stops the agent, and is five
; bytes. But the machine ALSO advertises its armed state with the keyboard
; lamp, and that lamp is driven by the keyboard itself, not by the flag byte
; -- so clearing the flag alone leaves a lit ScrollLock light on a box that
; is no longer stopped. Somebody standing at the machine would read that as
; still armed. So this also tells the keyboard to put the light out.
;
; The LED command is 0EDh followed by a bitmask, and the mask happens to fall
; out of the BIOS byte for free: flags bits 4,5,6 are Scroll, Num and Caps,
; and the LED mask bits 0,1,2 are Scroll, Num and Caps in the same order. One
; shift and a mask, so Num and Caps keep whatever state they were in.
;
; EVERY WAIT IS BOUNDED. This talks to the keyboard controller on a machine
; that, if it wedges, needs hands on it -- and the whole point of the program
; is to be run at the end of the agent loop, where nothing is left to report
; a hang. So each handshake spins at most 65536 times and then gives up: a
; keyboard that never answers costs a stale lamp, not a stopped box.
;
; Plain 8086 -- no 186 instructions -- so it runs on any DOS box. Assemble
; with NASM, which ships with FPC:
;
;     nasm -f bin scrloff.asm -o build\SCRLOFF.COM

%ifndef __MININASM__
cpu 8086
%endif

    org 100h

KBD_DATA    equ 60h
KBD_STAT    equ 64h
LED_CMD     equ 0EDh

start:
        mov     ax, 40h
        mov     ds, ax

        ; --- the half that matters: un-arm the agent ------------------
        and     byte [17h], 0EFh        ; clear bit 4, ScrollLock

        ; --- the lamp mask, straight out of the same byte -------------
        mov     al, [17h]
        mov     cl, 4
        shr     al, cl                  ; bits 4,5,6 -> 0,1,2
        and     al, 7                   ; Scroll, Num, Caps
        mov     bl, al

        ; --- tell the keyboard ----------------------------------------
        ; Interrupts off so the keyboard ISR does not swallow the ACK we
        ; are waiting for. Re-enabled on every exit path below.
        cli

        call    wait_write
        jc      finish
        mov     al, LED_CMD
        out     KBD_DATA, al
        call    wait_read               ; eat the ACK
        jc      finish

        call    wait_write
        jc      finish
        mov     al, bl
        out     KBD_DATA, al
        call    wait_read

finish:
        sti
        mov     ax, 4C00h
        int     21h

; ---------------------------------------------------------------------
; Wait until the controller will accept a byte: status bit 1 clear.
; CF set if it never does.
wait_write:
        push    cx
        xor     cx, cx
.spin:  in      al, KBD_STAT
        test    al, 2
        jz      .ready
        loop    .spin
        pop     cx
        stc
        ret
.ready: pop     cx
        clc
        ret

; ---------------------------------------------------------------------
; Wait for a byte back and read it: status bit 0 set. CF set on give-up.
; The byte itself is discarded -- we only need the handshake to advance.
wait_read:
        push    cx
        xor     cx, cx
.spin:  in      al, KBD_STAT
        test    al, 1
        jnz     .got
        loop    .spin
        pop     cx
        stc
        ret
.got:   in      al, KBD_DATA
        pop     cx
        clc
        ret
