[CmdletBinding()]
param(
    # Show what would change without changing anything. Worth having: the
    # script has no -WhatIf, and assuming it did is an easy way to put the
    # wrong folder on PATH while only meaning to look.
    [switch]$DryRun
)

# Installs the Windows half of dosbridge.
#
# Changes your system:
#   * appends the dosbridge folder and the FPC bin folder to your USER PATH
#   * adds inbound firewall rules for TCP 8080/8081/8082 and UDP 8069
#     (needs admin). The UDP rule is the important one: TFTP on 8069 is
#     the transport every job poll, file transfer and result travels on.
#   * creates the files/ serving directory
#
# Everything here is idempotent -- running it twice is harmless. It never
# touches the machine-wide PATH, and it never installs software: Python and
# Free Pascal must already be present. Run check.cmd first to see what is
# missing.

$ErrorActionPreference = 'Stop'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
# Same three layouts check.py handles: installed alongside this script, a
# built kit in kit\, or the repo two levels up. Getting this wrong put the
# Desktop on PATH instead of the folder actually holding dosd.py.
$RepoUp = Split-Path -Parent (Split-Path -Parent $Here)
if (Test-Path (Join-Path $Here 'dosd.py')) {
    $Root = $Here
} elseif (Test-Path (Join-Path $RepoUp 'dosd.py')) {
    $Root = $RepoUp
} elseif (Test-Path (Join-Path $Here 'kit\dosd.py')) {
    $Root = Join-Path $Here 'kit'
} else {
    $Root = $RepoUp
}

Write-Output ''
Write-Output "dosbridge folder : $Root"

# --- locate Free Pascal -----------------------------------------------------
$FpcRoot = $null
$cmd = Get-Command fpc.exe -ErrorAction SilentlyContinue
if ($cmd) {
    $FpcRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $cmd.Source))
} else {
    foreach ($base in @('C:\FPC', 'C:\lazarus\fpc')) {
        if (Test-Path $base) {
            $v = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
                 Sort-Object Name | Select-Object -Last 1
            if ($v) { $FpcRoot = $v.FullName; break }
        }
    }
}

$FpcBin = $null
if ($FpcRoot) {
    $FpcBin = Join-Path $FpcRoot 'bin\i386-win32'
    Write-Output "Free Pascal      : $FpcRoot"
    if (-not (Test-Path (Join-Path $FpcBin 'ppcross8086.exe'))) {
        Write-Output ''
        Write-Output "  WARNING: no ppcross8086.exe in $FpcBin"
        Write-Output "  The i8086-msdos cross-compiler is not installed, or you"
        Write-Output "  installed the x86_64 native compiler instead of i386-win32."
        Write-Output "  See README.md section 2 -- this is the classic wrong turn."
    }
} else {
    Write-Output "Free Pascal      : NOT FOUND (see README.md section 2)"
}

# --- PATH -------------------------------------------------------------------
Write-Output ''
Write-Output '--- PATH (user scope, no admin needed)'

$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($null -eq $userPath) { $userPath = '' }
$parts = @($userPath -split ';' | Where-Object { $_ -ne '' })

function Add-ToUserPath($dir) {
    if (-not $dir) { return $false }
    $norm = $dir.TrimEnd('\')
    foreach ($p in $script:parts) {
        if ($p.TrimEnd('\') -ieq $norm) {
            Write-Output "  already present : $dir"
            return $false
        }
    }
    $script:parts += $norm
    Write-Output "  added           : $dir"
    return $true
}

$changed = $false
if (Add-ToUserPath $Root)   { $changed = $true }
if (Add-ToUserPath $FpcBin) { $changed = $true }

if ($changed) {
    if ($DryRun) {
        Write-Output '  [dry run] would add to user PATH, no change made'
    } else {
        [Environment]::SetEnvironmentVariable('PATH', ($parts -join ';'), 'User')
    }
    Write-Output '  user PATH updated -- open a NEW terminal for it to take effect'
} else {
    Write-Output '  nothing to change'
}

# --- files/ -----------------------------------------------------------------
Write-Output ''
Write-Output '--- serving directory'
$Files = Join-Path $Root 'files'
if (Test-Path $Files) {
    Write-Output "  already present : $Files"
} else {
    New-Item -ItemType Directory $Files | Out-Null
    Write-Output "  created         : $Files"
}

# --- firewall ---------------------------------------------------------------
Write-Output ''
Write-Output '--- firewall (inbound TCP 8080-8082, UDP 8069)'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
             [Security.Principal.WindowsBuiltInRole]::Administrator)

# Two rules, and the UDP one is not optional. The bridge moved off mTCP onto
# its own TFTP transport, so UDP 8069 now carries the job poll, every file
# transfer and every result; the TCP ports are the legacy path. Opening only
# TCP produces a box that boots, prints a healthy banner and never polls --
# indistinguishable from a dead machine, which is why they are added together.
$Rules = @(
    @{ Name = 'dosbridge';      Proto = 'TCP'; Port = '8080,8081,8082' },
    @{ Name = 'dosbridge-tftp'; Proto = 'UDP'; Port = '8069' }
)

foreach ($r in $Rules) {
    $existing = Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Output ('  already present : rule "' + $r.Name + '"')
    } elseif (-not $admin) {
        Write-Output ('  SKIPPED -- needs Administrator: "' + $r.Name + '"')
        Write-Output '  Re-run this in an elevated terminal, or paste this into one:'
        Write-Output ''
        Write-Output ('    New-NetFirewallRule -DisplayName "' + $r.Name +
                      '" -Direction Inbound `')
        Write-Output ('      -Protocol ' + $r.Proto + ' -LocalPort ' + $r.Port +
                      ' -Action Allow -Profile Any')
        Write-Output ''
        Write-Output '  Without it the DOS box may poll forever and never be answered.'
    } else {
        # -Profile Any on purpose. A Private-only rule silently does nothing
        # when Windows has classified the network as Public, and the symptom is
        # a DOS box that never polls -- which looks like a dead machine, not a
        # firewall.
        if ($DryRun) {
            Write-Output ('  [dry run] would add rule "' + $r.Name + '"')
        } else {
            New-NetFirewallRule -DisplayName $r.Name -Direction Inbound `
                -Protocol $r.Proto -LocalPort $r.Port -Action Allow `
                -Profile Any | Out-Null
            Write-Output ('  created         : rule "' + $r.Name + '" (' +
                          $r.Proto + ' ' + $r.Port + ', profile Any)')
        }
    }
}

# --- done -------------------------------------------------------------------
Write-Output ''
# The paths below depend on which layout $Root was found in. Printing the
# repo's Installer\server\... paths to somebody running an installed kit sends
# them looking for folders that are not there: the kit is flat, so check.cmd
# sits beside them and the client kit builder is not present at all.
$InRepo = Test-Path (Join-Path $Root 'Installer\server\check.cmd')

Write-Output '--- next'
Write-Output '  1. Open a NEW terminal (PATH changes do not reach running shells)'
Write-Output ('  2. cd ' + $Root)
if ($InRepo) {
    Write-Output '  3. Installer\server\check.cmd     confirm everything is green'
} else {
    Write-Output '  3. check.cmd                      confirm everything is green'
}
Write-Output '  4. python selftest.py             Windows half, end to end'
Write-Output '     Run this BEFORE dosd.cmd. selftest starts its own dosd, so'
Write-Output '     it fails if one is already running.'
Write-Output '  5. dosd.cmd                       start the daemon, leave it running'
if ($InRepo) {
    Write-Output '  6. Installer\client\MAKEKIT.cmd   build the kit for the DOS machine'
} else {
    Write-Output '  6. build the DOS kit with client\MAKEKIT.cmd in the Installer'
    Write-Output '     folder you copied this from, then carry its kit\ across.'
}
Write-Output ''
Write-Output 'Steps 3-5 all run from the folder in step 2. The scripts locate'
Write-Output 'everything relative to themselves, so running them from elsewhere'
Write-Output 'finds nothing.'
Write-Output ''
