; elapsed.asm -- the job stopwatch behind the DOS console's footer line.
;
;   ELAPSED /S        stash the BIOS tick count; run at the start of a job
;   ELAPSED <text>    print <text> followed by the time since that stash
;
; Why one program does both, and why it prints the caller's text rather than
; just a number: the footer has to be ONE screen row. The console is 80
; columns, the agent's boot banner sits above it, and a job spending two rows
; on how it went would scroll the display away twice as fast. ECHO always
; terminates its line, so the only way to land "[bd01]   ok  1.4s" on a single
; row is for whatever holds the time to print the whole row itself.
;
; Plain 8086 -- no 186 instructions -- so it runs on any DOS box. Assemble
; with NASM, which ships with FPC:
;
;   nasm -f bin elapsed.asm -o build/ELAPSED.COM
;
; The syntax is MNASMFIX-compatible, so it also builds on the DOS box itself.
;
; Two limits, both deliberate. Only the LOW word of the tick counter is kept,
; so a job running longer than about an hour reports nonsense -- jobs here are
; seconds, dosd's own default timeout is 120s, and the alternative is 32-bit
; arithmetic for a status line. And a job spanning midnight reports nonsense
; for the same reason. Neither is worth the bytes.
;
; It reads 0040:006Ch directly rather than calling INT 1Ah AH=0. That call
; returns the midnight-rollover flag in AL and CLEARS it, and DOS reads that
; same flag to advance the date -- so a stopwatch built on it would
; occasionally eat a day.

    org 100h

; Let the assembler enforce the baseline rather than trusting a read-through.
; Guarded because mininasm has no CPU directive, and this file has to stay
; buildable on the DOS box.
%ifndef __MININASM__
    cpu 8086
%endif

TAIL    equ 81h                 ; PSP command tail, 0Dh-terminated
STDOUT  equ 1
BDA     equ 40h                 ; BIOS data area segment
TICKLO  equ 6Ch                 ; low word of the tick count

start:
        mov     si, TAIL
        ; Skip exactly one leading space. The command tail arrives verbatim,
        ; so "ELAPSED [bd01]   ok" gives " [bd01]   ok" -- one space more than
        ; ECHO would have printed, which would misalign this row against
        ; every other row on the screen by a column.
        cmp     byte [si], ' '
        jne     .nospace
        inc     si
.nospace:
        ; "/S" as the first thing on the tail means stash, and nothing else
        ; does. Looking for a bare '/' anywhere would misread any footer text
        ; that happened to contain one.
        cmp     byte [si], '/'
        jne     report
        mov     al, [si+1]
        or      al, 20h                 ; fold case: /S and /s both work
        cmp     al, 's'
        jne     report

; ---------------------------------------------------------------- stash mode
stash:
        mov     ax, BDA
        mov     es, ax
        mov     ax, [es:TICKLO]
        mov     [saved], ax

        mov     ah, 3Ch                 ; create/truncate
        xor     cx, cx
        mov     dx, fname
        int     21h
        jc      done                    ; no scratch dir? say nothing
        mov     bx, ax
        mov     ah, 40h
        mov     cx, 2
        mov     dx, saved
        int     21h
        mov     ah, 3Eh
        int     21h
done:
        mov     ax, 4C00h
        int     21h

; --------------------------------------------------------------- report mode
report:
        ; The caller's text goes out FIRST, so the footer still appears even
        ; if everything below it fails. A job that ran is worth more on screen
        ; than the time it took.
        mov     dx, si
        xor     cx, cx
.len:
        cmp     byte [si], 0Dh
        je      .gotlen
        inc     si
        inc     cx
        cmp     cx, 120                 ; the tail cannot exceed 127
        jb      .len
.gotlen:
        ; Trim trailing spaces. COMMAND.COM strips a redirection off the
        ; command line but leaves the space that preceded it in the tail, so
        ; the same footer text arrives a column wider when the caller happens
        ; to redirect. Alignment must not depend on that.
.trim:
        jcxz    .notext
        dec     si
        cmp     byte [si], ' '
        jne     .notrim
        dec     cx
        jmp     .trim
.notrim:
        inc     si
.notext_check:
        jcxz    .notext
        mov     bx, STDOUT
        mov     ah, 40h
        int     21h
.notext:

        mov     ax, 3D00h               ; open the stash read-only
        mov     dx, fname
        int     21h
        jc      notime
        mov     si, ax                  ; keep the handle out of BX's way
        mov     bx, si
        mov     ah, 3Fh
        mov     cx, 2
        mov     dx, saved
        int     21h
        mov     di, ax                  ; bytes actually read
        mov     bx, si
        mov     ah, 3Eh
        int     21h
        cmp     di, 2
        jne     notime

        mov     ax, BDA
        mov     es, ax
        mov     dx, [es:TICKLO]
        sub     dx, [saved]             ; unsigned, so a wrap within the hour
                                        ; still subtracts correctly

        ; tenths = delta * 50 / 91, because the tick is 18.2065 Hz.
        ; The quotient cannot overflow: 65535 * 50 / 91 = 36008.
        mov     ax, dx
        mov     dx, 50
        mul     dx                      ; DX:AX = delta * 50
        mov     cx, 91
        div     cx                      ; AX = tenths of a second

        ; Build "  N.Ns" + CRLF backwards from the end of the buffer, then
        ; write it in one call -- a character at a time through AH=02h would
        ; be six DOS calls for six bytes.
        mov     cx, 10
        xor     dx, dx
        div     cx                      ; AX = whole seconds, DX = tenths
        mov     di, obuf + 15
        mov     byte [di], 10           ; LF
        dec     di
        mov     byte [di], 13           ; CR
        dec     di
        mov     byte [di], 's'
        dec     di
        add     dl, '0'
        mov     [di], dl
        dec     di
        mov     byte [di], '.'
.digit:
        dec     di
        xor     dx, dx
        div     cx
        add     dl, '0'
        mov     [di], dl
        test    ax, ax
        jnz     .digit
        dec     di
        mov     byte [di], ' '
        dec     di
        mov     byte [di], ' '

        mov     dx, di
        mov     cx, obuf + 16
        sub     cx, di
        mov     bx, STDOUT
        mov     ah, 40h
        int     21h
        jmp     done

notime:
        ; Nothing to compare against. End the caller's line and stay quiet
        ; rather than printing a made-up duration.
        mov     dx, crlf
        mov     cx, 2
        mov     bx, STDOUT
        mov     ah, 40h
        int     21h
        jmp     done

; ------------------------------------------------------------------- data
fname:  db 'C:\WORK\ELAPSED.DAT', 0
crlf:   db 13, 10
saved:  dw 0
obuf:   times 16 db 0
