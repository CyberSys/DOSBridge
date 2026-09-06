{ net.pas -- IPv4 and UDP on top of the packet driver.

  DOS Bridge  --  StevenC

  WHY THIS EXISTS

  Everything the bridge sends or receives goes through this unit. It used to
  go through a third-party TCP/IP suite, which worked but was a dependency the
  installer kit could not ship -- the client README had to tell people to go
  and find it themselves -- and it cost several papercuts that are documented
  in CLAUDE.md: a version block printed to the console on every poll, queued
  keystrokes eaten out from under the agent loop, and an exit code of >= 20
  even on success.

  This unit is the bottom half of replacing it. `pktdrv`, `pktcap` and `arp`
  already proved we can find the driver, receive frames at interrupt time, and
  transmit -- what was missing was IPv4 and a transport. UDP is eight bytes
  and a checksum once IPv4 exists, which is why it comes first. TCP is not
  planned and should not be: see the "Where to go next" note in CLAUDE.md.

  WHAT IT DOES NOT DO

  No fragmentation, in either direction. Everything the bridge sends fits in
  one frame and anything arriving fragmented is dropped rather than
  reassembled -- a wrong reassembly is worse than a retry. No routing table
  beyond "is the peer on my subnet?"; if it is not, frames go to the gateway.
  No DNS, because the bridge talks to an IP address.

  THE RULE THAT MATTERS

  `NetOpen` hands the driver a far pointer to `PktRecv`, which it then calls
  at interrupt time for every matching frame. Exit without `NetClose` and that
  pointer dangles into memory DOS has since reused, and the next frame to
  arrive jumps into it. That is a machine with no network, and the bridge runs
  over that network -- recovery needs hands on the keyboard. So every exit
  path calls NetClose, including the error ones, and nothing between open and
  close does DOS I/O. }

unit Net;

{$MODE OBJFPC}{$H-}
{$ASMMODE INTEL}

interface

const
  { The bridge's network config. Written by the installer. }
  NET_CFG = 'C:\AI\NET.CFG';

  NET_MAXPKT = 1520;           { one Ethernet frame, with slack }
  NET_HDRLEN = 14 + 20 + 8;    { Ethernet + IPv4 + UDP }
  NET_MAXUDP = NET_MAXPKT - NET_HDRLEN;

type
  TIP  = packed array[0..3] of Byte;
  TMac = packed array[0..5] of Byte;

var
  NetMyIP    : TIP;            { IPADDR, out of the network config }
  NetMask    : TIP;
  NetGw      : TIP;
  NetMyMac   : TMac;           { from the driver, not the config }
  NetPeerIP  : TIP;            { who NetOpen was pointed at }
  NetPeerMac : TMac;           { the peer, or the gateway if off-subnet }
  NetViaGw   : Boolean;
  NetVec     : Byte;           { the packet driver's interrupt vector }
  NetErr     : ShortString;    { why the last call returned False }

  { Who the last datagram accepted by NetUdpRecv came from. TFTP needs this
    and it is not a detail: a TFTP server answers from a NEW ephemeral port
    (the "transfer identifier"), not from the port the request went to, and
    every subsequent packet of that transfer must be aimed at it. Reply to
    port 69 for the whole transfer and a correct server ignores you. }
  NetFromIP   : TIP;
  NetFromPort : Word;

  { Which config file the settings actually came from. Worth reporting: with
    two candidate locations, "wrong address" and "wrong file" look identical
    from the outside. }
  NetCfgUsed  : ShortString;

  { Called roughly once per BIOS tick while NetUdpRecv is waiting, so a
    caller can show that it is alive without this unit deciding what that
    should look like. Left nil it costs one comparison per spin.

    Doing DOS output from here is safe: our receiver runs at interrupt time
    but never calls DOS itself, so there is no reentrancy to worry about --
    the only cost is that a frame arriving mid-write is refused and the
    sender retransmits. Once a tick is far too rare to matter. }
  NetIdleHook : procedure;

  { Diagnostics. Cheap to keep and the first thing you want when a transfer
    goes quiet -- "nothing arrived" and "plenty arrived and none of it was
    for us" look identical from the outside otherwise. }
  NetRxFrames : Word;          { frames the handler accepted }
  NetRxDrop   : Word;          { frames refused: busy, or too big }
  NetRxWrong  : Word;          { arrived, parsed, not ours }
  NetTxFrames : Word;
  NetTxFail   : Word;          { send_pkt refused it -- driver buffer full }

function  NetReadConfig: Boolean;
function  NetFindDriver: Boolean;
function  NetOpen(const Peer: TIP): Boolean;
procedure NetClose;

function  NetUdpSend(SrcPort, DstPort: Word; var Data; Len: Word): Boolean;
function  NetUdpRecv(DstPort: Word; var Data; MaxLen: Word;
                     var GotLen: Word; TimeoutTicks: LongInt): Boolean;

function  NetTicks: LongInt;
function  IPStr(const A: TIP): ShortString;
function  MacStr(const M: TMac): ShortString;
function  ParseIP(S: ShortString; var A: TIP): Boolean;
function  SameNet(const A, B, M: TIP): Boolean;

implementation

uses Dos;                        { GetEnv }

type
  TPkt = array[0 .. NET_MAXPKT - 1] of Byte;
  PPkt = ^TPkt;

  { The layout the interrupt-time receiver below writes into. The assembler
    reaches these by hard-coded byte offsets, so DO NOT reorder or resize the
    fields ahead of Buf -- see the comment on PktRecv. Buf is TPkt rather than
    an anonymous array so it can be passed to the parsing helpers: in Pascal
    an anonymous array type will not bind to a named one as a var parameter. }
  TShared = packed record
    Busy     : Word;                                 { +0  }
    PktLen   : Word;                                 { +2  }
    PktCount : Word;                                 { +4  }
    Dropped  : Word;                                 { +6  }
    BytesLo  : Word;                                 { +8  }
    BytesHi  : Word;                                 { +10 }
    Buf      : TPkt;                                 { +12 }
  end;

const
  ETH_IP  = $0800;
  ETH_ARP = $0806;
  IPPROTO_UDP = 17;

var
  Shared  : TShared;
  Filt    : packed array[0..1] of Byte;
  Handler : packed record O, S: Word; end;
  TxBuf   : TPkt;
  Handle  : Word;
  CarryB  : Byte;
  ErrDH   : Byte;
  HaveDrv : Boolean;
  IsOpen  : Boolean;
  IPIdent : Word;

{ ------------------------------------------------------------------ }
{  The interrupt-time receiver.                                       }
{                                                                     }
{  Copied byte for byte from arp.pas, which is verified on hardware.  }
{  The first fourteen bytes are hand-written db/dw precisely because  }
{  two words need patching at run time and they have to sit at known  }
{  offsets: +7 is our data segment and +12 is Ofs(Shared). Let the    }
{  assembler pick its own encoding and those offsets stop being       }
{  knowable from Pascal. If you edit this prologue, re-check the      }
{  offsets against the linked binary before running it -- a wrong     }
{  patch corrupts an interrupt-time routine, which fails at the worst }
{  possible moment.                                                   }
{                                                                     }
{  The driver calls us twice per frame: AX=0 asks for a buffer of CX  }
{  bytes (return ES:DI, or 0:0 to drop it), AX=1 says it has been     }
{  copied in. Busy makes the second call safe to read from the main   }
{  loop: while it is set we refuse and count a drop rather than       }
{  overwrite a frame somebody is still reading.                       }
{ ------------------------------------------------------------------ }
procedure PktRecv; assembler; nostackframe;
asm
  db  01Eh              { push ds                       +0 }
  db  053h              { push bx                       +1 }
  db  051h              { push cx                       +2 }
  db  056h              { push si                       +3 }
  db  08Bh, 0F0h        { mov si, ax                 +4,+5 }
  db  0B8h              { mov ax, imm16                 +6 }
  dw  0                 {   patched: data segment       +7 }
  db  08Eh, 0D8h        { mov ds, ax                 +9,+10 }
  db  0BBh              { mov bx, imm16                +11 }
  dw  0                 {   patched: Ofs(Shared)       +12 }

  cmp  si, 0
  jne  @@second

  cmp  word ptr [bx], 0
  jne  @@refuse
  cmp  cx, NET_MAXPKT
  ja   @@refuse
  mov  ax, ds
  mov  es, ax
  mov  di, bx
  add  di, 12
  jmp  @@out

@@refuse:
  inc  word ptr [bx + 6]
  xor  ax, ax
  mov  es, ax
  xor  di, di
  jmp  @@out

@@second:
  inc  word ptr [bx + 4]
  mov  word ptr [bx + 2], cx
  add  word ptr [bx + 8], cx
  adc  word ptr [bx + 10], 0
  mov  word ptr [bx], 1

@@out:
  pop  si
  pop  cx
  pop  bx
  pop  ds
  retf
end;

{ ------------------------------------------------------------------ }
{  Small helpers                                                      }
{ ------------------------------------------------------------------ }

function NetTicks: LongInt;
begin
  NetTicks := MemL[$0040 : $006C];
end;

function Num(L: LongInt): ShortString;
var S: ShortString;
begin
  Str(L, S);
  Num := S;
end;

function Hex2(B: Byte): ShortString;
const HexD: array[0..15] of Char = '0123456789ABCDEF';
begin
  Hex2 := HexD[B shr 4] + HexD[B and $0F];
end;

function IPStr(const A: TIP): ShortString;
begin
  IPStr := Num(A[0]) + '.' + Num(A[1]) + '.' + Num(A[2]) + '.' + Num(A[3]);
end;

function MacStr(const M: TMac): ShortString;
var
  S: ShortString;
  I: Integer;
begin
  S := '';
  for I := 0 to 5 do
  begin
    if I > 0 then S := S + ':';
    S := S + Hex2(M[I]);
  end;
  MacStr := S;
end;

function SameNet(const A, B, M: TIP): Boolean;
var I: Integer;
begin
  SameNet := False;
  for I := 0 to 3 do
    if (A[I] and M[I]) <> (B[I] and M[I]) then Exit;
  SameNet := True;
end;

function ParseIP(S: ShortString; var A: TIP): Boolean;
var
  I, N, V: Integer;
  Ch: Char;
  Digits: Integer;
begin
  ParseIP := False;
  N := 0; V := 0; Digits := 0;
  for I := 1 to Length(S) + 1 do
  begin
    if I <= Length(S) then Ch := S[I] else Ch := '.';
    if (Ch >= '0') and (Ch <= '9') then
    begin
      V := V * 10 + (Ord(Ch) - Ord('0'));
      Inc(Digits);
      if (V > 255) or (Digits > 3) then Exit;
    end
    else if Ch = '.' then
    begin
      if (Digits = 0) or (N > 3) then Exit;
      A[N] := Byte(V);
      Inc(N); V := 0; Digits := 0;
    end
    else
      Exit;
  end;
  ParseIP := (N = 4);
end;

{ Big-endian store/load. Network order is the opposite of the x86's, and
  getting this backwards produces packets that look plausible in a hex dump
  and are silently discarded by every host on the wire. }
procedure PutW(var P: TPkt; Ofs, V: Word);
begin
  P[Ofs] := Hi(V);
  P[Ofs + 1] := Lo(V);
end;

function GetW(var P: TPkt; Ofs: Word): Word;
begin
  GetW := (Word(P[Ofs]) shl 8) or P[Ofs + 1];
end;

{ One's-complement sum, accumulated 16 bits at a time with the end-around
  carry done inline. A 32-bit accumulator would be the textbook version and
  is 5-8x dearer here (see the BENCH figures in CLAUDE.md); this stays in
  16-bit arithmetic, which on an 8086 is the difference that matters. }
procedure AddW(var S: Word; W: Word);
begin
  S := S + W;
  if S < W then Inc(S);          { the carry wraps around to the low end }
end;

procedure SumBuf(var S: Word; var P: TPkt; Ofs, Len: Word);
var I: Word;
begin
  I := 0;
  while (I + 1) < Len do
  begin
    AddW(S, (Word(P[Ofs + I]) shl 8) or P[Ofs + I + 1]);
    Inc(I, 2);
  end;
  { An odd trailing byte is padded on the right, not the left. }
  if I < Len then AddW(S, Word(P[Ofs + I]) shl 8);
end;

function Fold(S: Word): Word;
begin
  Fold := S xor $FFFF;
end;

{ ------------------------------------------------------------------ }
{  Configuration                                                      }
{                                                                     }
{  C:\AI\NET.CFG, which the installer writes.                        }
{                                                                     }
{  A legacy fallback follows it -- see NetReadConfig. Both files use   }
{  the same key names, which is why that fallback is one line rather   }
{  than a second parser.                                               }
{                                                                     }
{  Reading a file is a DOS operation, so it must happen -- and does   }
{  -- before any packet handle is ever opened.                        }
{ ------------------------------------------------------------------ }
function ReadCfgFile(const Cfg: ShortString; var GotIP: Boolean): Boolean;
var
  F     : Text;
  Line  : ShortString;
  I     : Integer;
  Key   : ShortString;
  Rest  : ShortString;
begin
  ReadCfgFile := False;
  if Cfg = '' then Exit;

  {$I-}
  Assign(F, Cfg);
  Reset(F);
  {$I+}
  if IOResult <> 0 then Exit;

  while not Eof(F) do
  begin
    {$I-}
    ReadLn(F, Line);
    {$I+}
    if IOResult <> 0 then Break;

    I := 1;
    while (I <= Length(Line)) and (Line[I] = ' ') do Inc(I);
    Key := '';
    while (I <= Length(Line)) and (Line[I] <> ' ') do
    begin
      Key := Key + UpCase(Line[I]);
      Inc(I);
    end;
    while (I <= Length(Line)) and (Line[I] = ' ') do Inc(I);
    Rest := '';
    while (I <= Length(Line)) and (Line[I] <> ' ') do
    begin
      Rest := Rest + Line[I];
      Inc(I);
    end;

    if Key = 'IPADDR' then
      GotIP := ParseIP(Rest, NetMyIP)
    else if Key = 'NETMASK' then
      ParseIP(Rest, NetMask)
    else if Key = 'GATEWAY' then
      ParseIP(Rest, NetGw);
  end;
  Close(F);
  NetCfgUsed := Cfg;
  ReadCfgFile := True;
end;

{ NET_CFG, then the legacy config named by %MTCPCFG%.

  Ours first, so a box carrying both is driven by the bridge's own settings
  rather than silently inheriting someone else's. The second path is a
  compatibility shim for machines configured before the bridge had a config of
  its own; nothing the installer produces needs it, and it can go once no such
  box is left. It is the last mention of that suite in this tree, and it is
  four lines. }
function NetReadConfig: Boolean;
var
  GotIP: Boolean;
begin
  NetReadConfig := False;
  GotIP := False;
  NetCfgUsed := '';
  { A sane default: if the config names no mask, assume a /24. Being wrong
    here only decides gateway-or-direct, and both are ARPed for. }
  NetMask[0] := 255; NetMask[1] := 255; NetMask[2] := 255; NetMask[3] := 0;
  FillChar(NetGw, SizeOf(NetGw), 0);

  if not ReadCfgFile(NET_CFG, GotIP) then
    if not ReadCfgFile(GetEnv('MTCPCFG'), GotIP) then
    begin
      NetErr := 'no network config: ' + NET_CFG;
      Exit;
    end;

  if not GotIP then
  begin
    NetErr := 'no usable IPADDR in ' + NetCfgUsed;
    Exit;
  end;
  NetReadConfig := True;
end;

{ ------------------------------------------------------------------ }
{  Packet driver plumbing                                             }
{                                                                     }
{  Calling a vector known only at run time needs a trick: the INT     }
{  opcode takes an immediate operand, so instead we PUSHF and far     }
{  CALL, which leaves the stack exactly as INT would and unwinds      }
{  correctly on the driver's IRET.                                    }
{                                                                     }
{  The fiddly part is that the call returns with DS pointing at the   }
{  DRIVER's segment, so until DS is put back every global here is     }
{  unreachable and storing a result would write into the driver. Move }
{  what you need into registers first, restore DS, then store -- MOV  }
{  does not touch the flags, so the carry the driver returned is      }
{  still valid when you test it.                                      }
{ ------------------------------------------------------------------ }
function NetFindDriver: Boolean;
const
  Sig = 'PKT DRVR';
var
  V, I: Integer;
  Sg, Of_: Word;
  Ok: Boolean;
begin
  NetFindDriver := False;
  if HaveDrv then
  begin
    NetFindDriver := True;
    Exit;
  end;
  for V := $60 to $80 do
  begin
    Of_ := MemW[0 : Word(V) * 4];
    Sg  := MemW[0 : Word(V) * 4 + 2];
    if Sg = 0 then Continue;
    Ok := True;
    for I := 1 to 8 do
      if Chr(Mem[Sg : Word(Of_ + 2 + I)]) <> Sig[I] then
      begin
        Ok := False; Break;
      end;
    if Ok then
    begin
      NetVec := Byte(V);
      Handler.O := Of_; Handler.S := Sg;
      HaveDrv := True;
      NetFindDriver := True;
      Exit;
    end;
  end;
  NetErr := 'no packet driver found on vectors 60h..80h';
end;

{ access_type (AH=02h) for one ethertype. }
function Acquire(EtherType: Word): Boolean;
var
  FOfs, RSeg, ROfs: Word;
begin
  Filt[0] := Hi(EtherType);        { the filter is in network order }
  Filt[1] := Lo(EtherType);
  Shared.Busy := 0;
  FOfs := Ofs(Filt);
  RSeg := Seg(PktRecv);
  ROfs := Ofs(PktRecv);
  asm
    push ds
    push es
    push si
    push di
    mov  ax, RSeg
    mov  es, ax
    mov  di, ROfs
    mov  si, FOfs
    mov  cx, 2
    mov  bx, 0FFFFh
    mov  dl, 0
    mov  ah, 2
    mov  al, 1
    pushf
    call far [Handler]
    mov  cx, ax
    mov  ax, dx
    pop  di
    pop  si
    pop  es
    pop  ds
    jnc  @@ok
    mov  CarryB, 1
    jmp  @@fin
  @@ok:
    mov  CarryB, 0
  @@fin:
    mov  Handle, cx
    mov  ErrDH, ah
  end;
  Acquire := (CarryB = 0);
  if CarryB <> 0 then
    NetErr := 'access_type refused for ethertype ' + Hex2(Hi(EtherType))
              + Hex2(Lo(EtherType)) + ', driver error ' + Num(ErrDH);
end;

{ release_type (AH=03h). }
procedure ReleaseHandle;
begin
  asm
    push ds
    mov  bx, Handle
    mov  ah, 3
    pushf
    call far [Handler]
    pop  ds
  end;
end;

{ get_address (AH=06h): our own MAC into ES:DI. Needs the handle, so it can
  only be called between Acquire and ReleaseHandle. }
procedure GetMyMac;
var
  MSeg, MOfs: Word;
begin
  MSeg := Seg(NetMyMac); MOfs := Ofs(NetMyMac);
  asm
    push ds
    push es
    push di
    mov  ax, MSeg
    mov  es, ax
    mov  di, MOfs
    mov  cx, 6
    mov  bx, Handle
    mov  ah, 6
    pushf
    call far [Handler]
    pop  di
    pop  es
    pop  ds
  end;
end;

{ send_pkt (AH=04h): DS:SI = frame, CX = length. No handle, no callback,
  nothing to release -- transmitting really is the easy half. }
{ send_pkt (AH=04h): DS:SI = frame, CX = length.

  The carry flag matters and was being thrown away. A driver whose transmit
  buffer is full returns carry set and sends NOTHING, which from the caller's
  side is indistinguishable from a packet lost on the wire -- except that
  retransmitting immediately will fail exactly the same way. Counting these
  separately is the difference between "the link is lossy" and "we are
  overrunning the card". }
procedure SendFrame(Len: Word);
var
  FOfs: Word;
begin
  FOfs := Ofs(TxBuf);
  asm
    push ds
    push si
    mov  si, FOfs
    mov  cx, Len
    mov  ah, 4
    pushf
    call far [Handler]
    pop  si
    pop  ds
    jnc  @@ok
    mov  CarryB, 1
    jmp  @@fin
  @@ok:
    mov  CarryB, 0
  @@fin:
  end;
  if CarryB <> 0 then Inc(NetTxFail) else Inc(NetTxFrames);
end;

{ Point the patched words in PktRecv at this program's data. }
procedure PatchRecv;
begin
  MemW[Seg(PktRecv) : Word(Ofs(PktRecv) + 7)]  := Seg(Shared);
  MemW[Seg(PktRecv) : Word(Ofs(PktRecv) + 12)] := Ofs(Shared);
end;

{ ------------------------------------------------------------------ }
{  ARP                                                                }
{ ------------------------------------------------------------------ }

procedure BuildArpRequest(const Target: TIP);
var I: Integer;
begin
  for I := 0 to 59 do TxBuf[I] := 0;
  for I := 0 to 5 do TxBuf[I] := $FF;                  { broadcast }
  for I := 0 to 5 do TxBuf[6 + I] := NetMyMac[I];
  PutW(TxBuf, 12, ETH_ARP);
  PutW(TxBuf, 14, 1);                                  { Ethernet }
  PutW(TxBuf, 16, ETH_IP);                             { resolving IPv4 }
  TxBuf[18] := 6;
  TxBuf[19] := 4;
  PutW(TxBuf, 20, 1);                                  { request }
  for I := 0 to 5 do TxBuf[22 + I] := NetMyMac[I];
  for I := 0 to 3 do TxBuf[28 + I] := NetMyIP[I];
  { 32..37 target MAC stays zero -- it is what we are asking for }
  for I := 0 to 3 do TxBuf[38 + I] := Target[I];
end;

{ Send an ARP request and wait for the matching reply.

  The sender address matters and is easy to get wrong: the packet driver has
  no idea what our IP is -- addresses are a concept one layer up -- so it has
  to come from the config. An earlier version of arp.pas guessed ".0" of the
  target's range and got no replies at all, because .0 is a network address
  that well-behaved hosts are right to ignore. }
function ArpResolve(const Target: TIP; var M: TMac; Tries: Integer;
                    PerTry: LongInt): Boolean;
var
  Attempt : Integer;
  Deadline, T0: LongInt;
  L, I    : Word;
  Ok      : Boolean;
begin
  ArpResolve := False;
  for Attempt := 1 to Tries do
  begin
    BuildArpRequest(Target);
    Shared.Busy := 0;
    SendFrame(60);

    T0 := NetTicks;
    Deadline := T0 + PerTry;
    repeat
      if Shared.Busy <> 0 then
      begin
        L := Shared.PktLen;
        Ok := (L >= 42)
              and (Shared.Buf[12] = $08) and (Shared.Buf[13] = $06)
              and (Shared.Buf[20] = $00) and (Shared.Buf[21] = $02);
        if Ok then
          for I := 0 to 3 do
            if Shared.Buf[28 + I] <> Target[I] then Ok := False;
        if Ok then
        begin
          for I := 0 to 5 do M[I] := Shared.Buf[22 + I];
          Shared.Busy := 0;
          ArpResolve := True;
          Exit;
        end;
        Inc(NetRxWrong);
        Shared.Busy := 0;
      end;
      { NetTicks wraps at midnight. Treat a counter that has gone backwards
        as "time is up" rather than looping for another 24 hours. }
    until (NetTicks >= Deadline) or (NetTicks < T0);
  end;
  NetErr := 'no ARP reply from ' + IPStr(Target);
end;

{ ------------------------------------------------------------------ }
{  Open / close                                                       }
{ ------------------------------------------------------------------ }

{ Resolve the peer, then hold a handle for IPv4.

  Two handles are NOT held at once. The packet driver spec lets a driver
  refuse a second access_type for a type already in use, and behaviour when
  two handles want the same type is not something to depend on -- so the ARP
  phase opens 0806, finishes, releases, and only then does the IP phase open
  0800. Sequential, never concurrent. The same reasoning is why this can
  coexist with any other packet-driver program on the box -- PKTCAP, ARP,
  anything else resident: they are separate programs that never hold a handle
  at the same moment. }
function NetOpen(const Peer: TIP): Boolean;
var
  Whom: TIP;
begin
  NetOpen := False;
  NetErr := '';
  if IsOpen then
  begin
    NetErr := 'NetOpen called twice without NetClose';
    Exit;
  end;
  if not NetFindDriver then Exit;

  NetPeerIP := Peer;
  PatchRecv;

  { --- ARP phase ------------------------------------------------- }
  if not Acquire(ETH_ARP) then Exit;
  GetMyMac;

  NetViaGw := not SameNet(NetMyIP, Peer, NetMask);
  if NetViaGw then Whom := NetGw else Whom := Peer;

  if (Whom[0] or Whom[1] or Whom[2] or Whom[3]) = 0 then
  begin
    ReleaseHandle;
    NetErr := IPStr(Peer) + ' is off-subnet and no GATEWAY is configured';
    Exit;
  end;

  if not ArpResolve(Whom, NetPeerMac, 3, 18) then
  begin
    ReleaseHandle;
    Exit;
  end;
  ReleaseHandle;

  { --- IP phase -------------------------------------------------- }
  if not Acquire(ETH_IP) then Exit;
  IsOpen := True;
  NetOpen := True;
end;

procedure NetClose;
begin
  if not IsOpen then Exit;
  ReleaseHandle;
  IsOpen := False;
end;

{ ------------------------------------------------------------------ }
{  UDP                                                                }
{ ------------------------------------------------------------------ }

function NetUdpSend(SrcPort, DstPort: Word; var Data; Len: Word): Boolean;
var
  I, Total, UdpLen, Ck: Word;
  Src: PPkt;
  S: Word;
begin
  NetUdpSend := False;
  if not IsOpen then
  begin
    NetErr := 'NetUdpSend before NetOpen';
    Exit;
  end;
  if Len > NET_MAXUDP then
  begin
    NetErr := 'payload ' + Num(Len) + ' exceeds ' + Num(NET_MAXUDP)
              + ' -- this unit does not fragment';
    Exit;
  end;

  Src    := PPkt(@Data);
  UdpLen := 8 + Len;
  Total  := 14 + 20 + UdpLen;
  FillChar(TxBuf, SizeOf(TxBuf), 0);

  { Ethernet }
  for I := 0 to 5 do TxBuf[I] := NetPeerMac[I];
  for I := 0 to 5 do TxBuf[6 + I] := NetMyMac[I];
  PutW(TxBuf, 12, ETH_IP);

  { IPv4 }
  TxBuf[14] := $45;                       { version 4, 20-byte header }
  TxBuf[15] := 0;                         { DSCP/ECN }
  PutW(TxBuf, 16, 20 + UdpLen);           { total length }
  Inc(IPIdent);
  PutW(TxBuf, 18, IPIdent);
  PutW(TxBuf, 20, 0);                     { no flags, no fragment offset }
  TxBuf[22] := 64;                        { TTL }
  TxBuf[23] := IPPROTO_UDP;
  PutW(TxBuf, 24, 0);                     { checksum, filled in below }
  for I := 0 to 3 do TxBuf[26 + I] := NetMyIP[I];
  for I := 0 to 3 do TxBuf[30 + I] := NetPeerIP[I];
  S := 0;
  SumBuf(S, TxBuf, 14, 20);
  PutW(TxBuf, 24, Fold(S));

  { UDP }
  PutW(TxBuf, 34, SrcPort);
  PutW(TxBuf, 36, DstPort);
  PutW(TxBuf, 38, UdpLen);
  PutW(TxBuf, 40, 0);                     { checksum, filled in below }
  { Guarded: Len is a Word, so "0 to Len - 1" with Len = 0 counts to 65535. }
  if Len > 0 then
    for I := 0 to Len - 1 do TxBuf[42 + I] := Src^[I];

  { UDP's checksum covers a pseudo-header of the IP addresses, the protocol
    and the UDP length, as well as the datagram itself. It is optional in
    IPv4 -- zero means "not computed" -- but computing it costs almost
    nothing here and it is the only end-to-end check on the payload. }
  S := 0;
  SumBuf(S, TxBuf, 26, 8);                { source and destination IP }
  AddW(S, IPPROTO_UDP);
  AddW(S, UdpLen);
  SumBuf(S, TxBuf, 34, UdpLen);
  Ck := Fold(S);
  { An all-zero checksum on the wire means "none sent", so the one's
    complement rule is to transmit it as all ones instead. }
  if Ck = 0 then Ck := $FFFF;
  PutW(TxBuf, 40, Ck);

  { Ethernet's minimum payload is 46 bytes; pad short frames rather than
    relying on the card to do it. FillChar already zeroed the tail. }
  if Total < 60 then Total := 60;
  SendFrame(Total);
  NetUdpSend := True;
end;

{ Wait for one UDP datagram addressed to DstPort.

  Anything else that arrives on the handle -- and on a busy LAN plenty will,
  since we asked for every IPv4 frame -- is counted and discarded. That
  counting is not decoration: "nothing came back" and "lots came back and
  none of it was ours" are the same silence from the caller's side, and they
  have completely different causes. }
function NetUdpRecv(DstPort: Word; var Data; MaxLen: Word;
                    var GotLen: Word; TimeoutTicks: LongInt): Boolean;
var
  T0, Deadline, LastTick, Now: LongInt;
  L, Ihl, UdpLen, PayOfs, PayLen, I: Word;
  Dst: PPkt;
  Ok: Boolean;
begin
  NetUdpRecv := False;
  GotLen := 0;
  Dst := PPkt(@Data);
  if not IsOpen then
  begin
    NetErr := 'NetUdpRecv before NetOpen';
    Exit;
  end;

  T0 := NetTicks;
  Deadline := T0 + TimeoutTicks;
  LastTick := T0;
  repeat
    if NetIdleHook <> nil then
    begin
      Now := NetTicks;
      if Now <> LastTick then
      begin
        LastTick := Now;
        NetIdleHook;
      end;
    end;
    if Shared.Busy <> 0 then
    begin
      Inc(NetRxFrames);
      L := Shared.PktLen;
      Ok := False;

      if (L >= NET_HDRLEN)
         and (Shared.Buf[12] = $08) and (Shared.Buf[13] = $00)
         and ((Shared.Buf[14] shr 4) = 4) then
      begin
        Ihl := (Shared.Buf[14] and $0F) * 4;
        { A fragment has a non-zero offset or the More Fragments bit set.
          Reassembly is not implemented, so drop it rather than hand the
          caller half a datagram that looks whole. }
        if (Ihl >= 20) and (L >= 14 + Ihl + 8)
           and (Shared.Buf[14 + 9] = IPPROTO_UDP)
           and ((GetW(Shared.Buf, 14 + 6) and $3FFF) = 0) then
        begin
          Ok := True;
          for I := 0 to 3 do
            if Shared.Buf[14 + 16 + I] <> NetMyIP[I] then Ok := False;
          if Ok and (GetW(Shared.Buf, 14 + Ihl + 2) <> DstPort) then
            Ok := False;
          if Ok then
          begin
            UdpLen := GetW(Shared.Buf, 14 + Ihl + 4);
            if (UdpLen < 8) or (L < 14 + Ihl + UdpLen) then
              Ok := False
            else
            begin
              PayOfs := 14 + Ihl + 8;
              PayLen := UdpLen - 8;
              if PayLen > MaxLen then PayLen := MaxLen;
              if PayLen > 0 then
                for I := 0 to PayLen - 1 do Dst^[I] := Shared.Buf[PayOfs + I];
              GotLen := PayLen;
              for I := 0 to 3 do NetFromIP[I] := Shared.Buf[14 + 12 + I];
              NetFromPort := GetW(Shared.Buf, 14 + Ihl);
            end;
          end;
        end;
      end;

      if not Ok then Inc(NetRxWrong);
      Shared.Busy := 0;
      if Ok then
      begin
        NetUdpRecv := True;
        Exit;
      end;
    end;
  until (NetTicks >= Deadline) or (NetTicks < T0);

  NetRxDrop := Shared.Dropped;
  NetErr := 'timed out waiting for a UDP reply on port ' + Num(DstPort);
end;

begin
  HaveDrv := False;
  IsOpen  := False;
  IPIdent := 0;
  NetIdleHook := nil;
  NetErr  := '';
  NetRxFrames := 0;
  NetRxDrop   := 0;
  NetRxWrong  := 0;
  NetTxFrames := 0;
  NetTxFail   := 0;
end.
