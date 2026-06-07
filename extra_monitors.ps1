<#
.SYNOPSIS
    Extra Monitors VNC Script (Windows equivalent of extra_monitors.sh)

.DESCRIPTION
    Turns an Android phone into an extra monitor over VNC.

    Architecture (mirrors the Linux x11vnc script, adapted for Windows):
      * A physical dummy HDMI plug provides a real secondary monitor (the
        "extra" desktop space). Set its Windows resolution to your phone's
        landscape resolution so it is served 1:1.
      * UltraVNC serves ONLY that secondary monitor on port 5900
        (primary=0 / secondary=1, mirror driver required).
      * ADB tunnels 5900 to the phone (adb reverse), wakes it, forces
        landscape, launches bVNC Free and auto-connects to
        vnc://127.0.0.1:5900.

    Unlike x11vnc, UltraVNC selects whole monitors (not arbitrary
    rectangles) and requires a password, so the script sets a known VNC
    password and embeds it in the bVNC connect URI.

.NOTES
    Requires: Chocolatey, administrator rights. Installs UltraVNC + adb.
    Press Ctrl+C to stop gracefully (kills winvnc, removes adb reverse).
#>

param(
    [string]$TargetDeviceSerial = $(if ($env:TARGET_DEVICE_SERIAL) { $env:TARGET_DEVICE_SERIAL } else { 'G0K0KH02616100TX' }),
    [int]   $VncPort            = $(if ($env:VNC_PORT)            { [int]$env:VNC_PORT }       else { 5900 }),
    [string]$VncPassword        = $(if ($env:VNC_PASSWORD)        { $env:VNC_PASSWORD }        else { 'monitor1' }),
    [string]$BvncPackage        = $(if ($env:BVNC_PACKAGE)        { $env:BVNC_PACKAGE }        else { 'com.iiordanov.freebVNC' })
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Log-Info    { param([string]$Msg) Write-Host "[INFO] "    -ForegroundColor Blue   -NoNewline; Write-Host $Msg }
function Log-Success { param([string]$Msg) Write-Host "[SUCCESS] " -ForegroundColor Green  -NoNewline; Write-Host $Msg }
function Log-Warning { param([string]$Msg) Write-Host "[WARNING] " -ForegroundColor Yellow -NoNewline; Write-Host $Msg }
function Log-Error   { param([string]$Msg) Write-Host "[ERROR] "   -ForegroundColor Red    -NoNewline; Write-Host $Msg }

# ---------------------------------------------------------------------------
# Elevation: UltraVNC install/config and winvnc need administrator rights.
# Relaunch self elevated (keeping the window open for the live loop).
# ---------------------------------------------------------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Log-Warning "Administrator rights required. Relaunching elevated..."
    $argList = @(
        '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
        '-TargetDeviceSerial', $TargetDeviceSerial,
        '-VncPort', $VncPort,
        '-VncPassword', $VncPassword,
        '-BvncPackage', $BvncPackage
    )
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
    } catch {
        Log-Error "Failed to elevate: $($_.Exception.Message)"
    }
    return
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$script:UltraVncDir = $null
$script:WinVncExe   = $null
$script:AdbDevices  = @()

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
function Test-Choco {
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Log-Error "Chocolatey is not installed. Install it first (run as admin):"
        Log-Info  'Set-ExecutionPolicy Bypass -Scope Process -Force; ' +
                  '[System.Net.ServicePointManager]::SecurityProtocol = 3072; ' +
                  'iex ((New-Object System.Net.WebClient).DownloadString(''https://community.chocolatey.org/install.ps1''))'
        return $false
    }
    return $true
}

function Install-Package {
    param([string]$Id, [string]$Probe)
    if ($Probe -and (Get-Command $Probe -ErrorAction SilentlyContinue)) {
        Log-Info "$Id already available ($Probe found). Skipping install."
        return
    }
    Log-Info "Installing $Id via Chocolatey..."
    choco install $Id -y --no-progress | Out-Null
    if ($LASTEXITCODE -eq 0) { Log-Success "$Id installed." }
    else { Log-Warning "choco install $Id returned exit code $LASTEXITCODE." }
}

function Resolve-UltraVnc {
    $candidates = @(
        "$env:ProgramFiles\uvnc bvba\UltraVNC",
        "${env:ProgramFiles(x86)}\uvnc bvba\UltraVNC",
        "$env:ProgramFiles\UltraVNC",
        "${env:ProgramFiles(x86)}\UltraVNC"
    )
    foreach ($dir in $candidates) {
        if ($dir -and (Test-Path (Join-Path $dir 'winvnc.exe'))) {
            $script:UltraVncDir = $dir
            $script:WinVncExe   = Join-Path $dir 'winvnc.exe'
            Log-Success "Found UltraVNC at $dir"
            return $true
        }
    }
    # Fallback: search Program Files for winvnc.exe
    Log-Info "Searching for winvnc.exe under Program Files..."
    $found = Get-ChildItem -Path $env:ProgramFiles, ${env:ProgramFiles(x86)} -Filter 'winvnc.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
        $script:WinVncExe   = $found.FullName
        $script:UltraVncDir = $found.DirectoryName
        Log-Success "Found UltraVNC at $($found.DirectoryName)"
        return $true
    }
    Log-Error "Could not locate winvnc.exe. Is UltraVNC installed?"
    return $false
}

function Test-MirrorDriver {
    # The primary/secondary monitor selection needs the UltraVNC mirror driver.
    # Best-effort detection only; warn (do not hard-fail) if not found.
    $hit = $false
    try {
        $drivers = & pnputil.exe /enum-drivers 2>$null | Out-String
        if ($drivers -match '(?i)mirror|ultravnc|uvnc') { $hit = $true }
    } catch { }
    if (-not $hit) {
        try {
            $disp = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
            if ($disp.Name -match '(?i)mirror|ultravnc') { $hit = $true }
        } catch { }
    }
    if ($hit) {
        Log-Success "UltraVNC mirror driver appears to be installed."
    } else {
        Log-Warning "UltraVNC mirror driver not detected. primary/secondary monitor"
        Log-Warning "selection may not work. Install it from the UltraVNC settings"
        Log-Warning "(uvnc_settings.exe) or the UltraVNC installer, then re-run."
    }
}

# ---------------------------------------------------------------------------
# Display detection (dummy plug = real secondary monitor)
# ---------------------------------------------------------------------------
function Log-MonitorPlacement {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $screens = [System.Windows.Forms.Screen]::AllScreens
    Log-Info "Current monitor placement:"
    foreach ($s in $screens) {
        $tag = if ($s.Primary) { 'primary' } else { 'secondary' }
        $b = $s.Bounds
        Log-Info ("  {0} [{1}] {2}x{3}+{4}+{5}" -f $s.DeviceName, $tag, $b.Width, $b.Height, $b.X, $b.Y)
    }
    $secondary = $screens | Where-Object { -not $_.Primary }
    if (-not $secondary) {
        Log-Warning "No secondary monitor detected. Seat your dummy HDMI plug and"
        Log-Warning "confirm Windows shows it as a separate (non-primary) display."
        return $false
    }
    Log-Success ("Secondary monitor detected: {0} ({1}x{2})" -f $secondary[0].DeviceName, $secondary[0].Bounds.Width, $secondary[0].Bounds.Height)
    return $true
}

# ---------------------------------------------------------------------------
# UltraVNC configuration
# ---------------------------------------------------------------------------
function Get-VncPasswordHex {
    # Reproduces the VNC password "encryption": standard DES/ECB with the
    # well-known fixed key (bytes already bit-reversed per the VNC convention),
    # encrypting the 8-byte (null-padded/truncated) password. UltraVNC stores
    # the resulting 8 bytes as 16 hex chars in passwd= / passwd2=.
    param([string]$Password)
    $key = [byte[]](0xE8, 0x4A, 0xD6, 0x60, 0xC4, 0x72, 0x1A, 0xE0)
    $pw  = New-Object byte[] 8
    $src = [System.Text.Encoding]::ASCII.GetBytes($Password)
    [Array]::Copy($src, $pw, [Math]::Min(8, $src.Length))

    $des = [System.Security.Cryptography.DES]::Create()
    $des.Key     = $key
    $des.Mode    = [System.Security.Cryptography.CipherMode]::ECB
    $des.Padding = [System.Security.Cryptography.PaddingMode]::None
    $enc = $des.CreateEncryptor()
    $out = $enc.TransformFinalBlock($pw, 0, 8)
    $des.Dispose()
    ($out | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Set-UltraVncIni {
    param([string]$Path, [hashtable]$Settings)
    if (Test-Path -LiteralPath $Path) {
        $lines = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $Path)
    } else {
        $lines = [System.Collections.Generic.List[string]]@('[ultravnc]')
    }
    foreach ($key in $Settings.Keys) {
        $val = $Settings[$key]
        $idx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^\s*$([regex]::Escape($key))\s*=") { $idx = $i; break }
        }
        if ($idx -ge 0) {
            $lines[$idx] = "$key=$val"
        } else {
            $hdr = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*\[ultravnc\]\s*$') { $hdr = $i; break }
            }
            if ($hdr -ge 0) { $lines.Insert($hdr + 1, "$key=$val") }
            else { $lines.Insert(0, "$key=$val"); $lines.Insert(0, '[ultravnc]') }
        }
    }
    Set-Content -LiteralPath $Path -Value $lines -Encoding ASCII
}

function Configure-UltraVnc {
    $iniPath = Join-Path $script:UltraVncDir 'ultravnc.ini'
    Log-Info "Configuring UltraVNC ($iniPath)..."
    $hex = Get-VncPasswordHex -Password $VncPassword
    Set-UltraVncIni -Path $iniPath -Settings @{
        PortNumber    = $VncPort   # main VNC port
        primary       = 0          # do NOT serve the primary monitor
        secondary     = 1          # serve ONLY the secondary monitor (dummy plug)
        EnableDriver  = 1          # use the mirror driver (needed for monitor selection)
        AllowLoopback = 1          # phone connects via adb reverse -> 127.0.0.1
        LoopbackOnly  = 1          # restrict to loopback (only the tunneled phone)
        passwd        = $hex       # full-control password
        passwd2       = $hex       # view-only password (same)
        FileTransferEnabled = 0
    }
    Log-Success "UltraVNC configured: secondary monitor on port $VncPort, loopback-only."
}

# ---------------------------------------------------------------------------
# ADB
# ---------------------------------------------------------------------------
function Discover-AdbDevices {
    $script:AdbDevices = @()
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
        Log-Warning "ADB is not installed. Android automation will be skipped."
        return $false
    }
    Log-Info "Starting ADB server..."
    & adb start-server *> $null

    Log-Info "Checking connected Android devices (adb devices)..."
    & adb devices

    $devices = (& adb devices) |
        Select-Object -Skip 1 |
        Where-Object { $_ -match '\sdevice\s*$' } |
        ForEach-Object { ($_ -split '\s+')[0] }

    if (-not $devices) {
        Log-Warning "No authorized Android devices found. Accept the USB debugging prompt and retry."
        return $false
    }

    if ($devices -contains $TargetDeviceSerial) {
        $script:AdbDevices = @($TargetDeviceSerial)
        Log-Success "Target device detected: $TargetDeviceSerial"
    } else {
        $script:AdbDevices = @($devices)
        Log-Warning "Target device $TargetDeviceSerial not connected. Using: $($devices -join ' ')"
    }
    return $true
}

function Show-PhoneResolutionHint {
    if (-not $script:AdbDevices) { return }
    $device = $script:AdbDevices[0]
    $wm = (& adb -s $device shell wm size) -join "`n"
    if ($wm -match 'Physical size:\s*(\d+)x(\d+)') {
        $w = [int]$Matches[1]; $h = [int]$Matches[2]
        $land = if ($h -gt $w) { "$h x $w" } else { "$w x $h" }
        Log-Info "Phone physical resolution: $($Matches[1])x$($Matches[2])."
        Log-Info "For a sharp 1:1 image, set the dummy monitor's Windows resolution to $land (landscape)."
    }
}

function Open-AdbReverse {
    if (-not $script:AdbDevices) { return }
    Log-Info "Opening port $VncPort on the phone via adb reverse..."
    foreach ($device in $script:AdbDevices) {
        & adb -s $device reverse --remove "tcp:$VncPort" *> $null
        & adb -s $device reverse "tcp:$VncPort" "tcp:$VncPort" *> $null
        if ($LASTEXITCODE -eq 0) {
            Log-Success "Port $VncPort tunneled for $device (use 127.0.0.1:$VncPort in bVNC)."
        } else {
            Log-Error "Failed to open port $VncPort for $device."
        }
    }
}

function Wake-AndOpenBvnc {
    if (-not $script:AdbDevices) { return }
    Log-Info "Waking phone screen and launching bVNC Free..."
    $uri = "vnc://:$VncPassword@127.0.0.1:$VncPort"
    foreach ($device in $script:AdbDevices) {
        & adb -s $device shell input keyevent KEYCODE_WAKEUP *> $null
        & adb -s $device shell input keyevent 82 *> $null
        # Force landscape for a landscape monitor feed.
        & adb -s $device shell settings put system accelerometer_rotation 0 *> $null
        & adb -s $device shell settings put system user_rotation 1 *> $null

        & adb -s $device shell monkey -p $BvncPackage -c android.intent.category.LAUNCHER 1 *> $null
        if ($LASTEXITCODE -eq 0) {
            Log-Success "bVNC Free opened on $device."
        } else {
            Log-Warning "Could not open bVNC Free on $device. Is $BvncPackage installed?"
            continue
        }
        # Best-effort auto-connect (credentials embedded in the URI).
        & adb -s $device shell am start -a android.intent.action.VIEW -d "`"$uri`"" *> $null
        if ($LASTEXITCODE -eq 0) {
            Log-Success "Attempted VNC auto-connect via $uri on $device."
        } else {
            Log-Warning "Could not auto-start the VNC connection on $device. Connect manually in bVNC."
        }
    }
}

function Cleanup-AdbReverse {
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { return }
    Log-Info "Cleaning up ADB port forwarding..."
    foreach ($device in $script:AdbDevices) {
        & adb -s $device reverse --remove-all *> $null
    }
}

# ---------------------------------------------------------------------------
# winvnc lifecycle
# ---------------------------------------------------------------------------
function Start-WinVnc {
    Log-Info "Starting UltraVNC server on port $VncPort (secondary monitor)..."
    # Restart cleanly so the new ini is picked up.
    & $script:WinVncExe -kill *> $null
    Start-Sleep -Milliseconds 500
    Start-Process -FilePath $script:WinVncExe -ArgumentList '-run' | Out-Null
    Start-Sleep -Seconds 1
    if (Get-Process -Name 'winvnc' -ErrorAction SilentlyContinue) {
        Log-Success "UltraVNC server started."
        return $true
    }
    Log-Error "UltraVNC server failed to start."
    return $false
}

function Stop-WinVnc {
    if (-not $script:WinVncExe) { return }
    Log-Info "Stopping UltraVNC server..."
    & $script:WinVncExe -kill *> $null
    Start-Sleep -Milliseconds 500
    Get-Process -Name 'winvnc' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Cleanup {
    Write-Host ''
    Log-Info "Shutting down gracefully..."
    Cleanup-AdbReverse
    Stop-WinVnc
    Log-Success "Stopped successfully."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Main {
    Log-Info "=== Starting Extra Monitors VNC Script (Windows) ==="

    if (-not (Test-Choco)) { return }
    Install-Package -Id 'ultravnc' -Probe $null
    Install-Package -Id 'adb'      -Probe 'adb'

    if (-not (Resolve-UltraVnc)) { return }
    Test-MirrorDriver
    Log-MonitorPlacement | Out-Null

    Configure-UltraVnc

    Discover-AdbDevices | Out-Null
    Show-PhoneResolutionHint
    Open-AdbReverse

    if (-not (Start-WinVnc)) {
        Cleanup
        return
    }

    Log-Info "VNC server is running. Press Ctrl+C to stop gracefully."
    Log-Info "Connect to: 127.0.0.1:$VncPort (secondary monitor / dummy plug)."

    Wake-AndOpenBvnc

    try {
        # Monitor loop: exit when winvnc stops; Ctrl+C triggers finally cleanup.
        while ($true) {
            if (-not (Get-Process -Name 'winvnc' -ErrorAction SilentlyContinue)) {
                Log-Warning "UltraVNC server has stopped."
                break
            }
            Start-Sleep -Seconds 2
        }
    } finally {
        Cleanup
    }
}

Main
