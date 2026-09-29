# Bootstrap WinRM so Packer can communicate with the building VM.
# Runs as a FirstLogonCommand via Autounattend.xml (fallback layer — the
# specialize pass in Autounattend.xml already enables WinRM inline before
# OOBE; this script re-applies everything and installs the bundled ARM64
# drivers best-effort).
#
# Ordering note (regression observed 2026-09-29): WinRM + firewall MUST run
# first with no drive dependency. USB CD-ROM drive letters can lag first
# logon by seconds, so the old one-shot drive scan ran before the CD was
# mounted, silently did nothing, and WinRM never came up. The driver scan
# below now waits for the CD instead.
#
# Step 1: Configure WinRM listener, auth, firewall (no drive dependency).
# Step 2: Install VirtIO NetKVM/viostor drivers via pnputil, waiting for the
#   unattend CD (label "UNATTEND") to get a drive letter.

$ErrorActionPreference = 'Stop'

Write-Host "Configuring WinRM for Packer communication..."

# Private profile first: WinRM cmdlets warn or bail while any adapter is on
# the Public profile. The QEMU slirp NIC lands as unidentified/Public.
Get-NetConnectionProfile -ErrorAction SilentlyContinue |
    Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue

# Enable the WinRM listener. -SkipNetworkProfileCheck is required because the
# QEMU slirp NIC often lands on a Public/unidentified network profile, which
# would otherwise stop the listener from being created.
Enable-PSRemoting -Force -SkipNetworkProfileCheck

# For the build only: turn the firewall off entirely so nothing blocks inbound
# WinRM on 5985, regardless of network profile.
netsh advfirewall set allprofiles state off

# Allow unencrypted and Basic auth (Packer's default Windows transport).
Set-Item WSMan:\localhost\Service\AllowUnencrypted $true
Set-Item WSMan:\localhost\Service\Auth\Basic $true
Set-Item WSMan:\localhost\Client\AllowUnencrypted $true
Set-Item WSMan:\localhost\Client\Auth\Basic $true

# Increase timeout for slow builds
winrm set winrm/config '@{MaxTimeoutms="1800000"}'

# Ensure WinRM starts automatically and is running
sc.exe config WinRM start= auto
Restart-Service -Name WinRM -Force

Write-Host "WinRM configured successfully."

# --- Best-effort driver install (non-fatal) ---
# NetKVM/viostor are also staged during WinPE via the PnpCustomizationsWinPE
# DriverPaths, so a missed scan here must not break the bootstrap.
Write-Host "Installing VirtIO drivers (waiting for unattend CD)..."
$driverRoot = $null
for ($i = 0; $i -lt 45 -and -not $driverRoot; $i++) {
    foreach ($l in 'D','E','F','G','H','I') {
        $p = "${l}:\drivers"
        if (Test-Path $p) {
            $driverRoot = $p
            Write-Host "Found drivers at: $p"
            break
        }
    }
    if (-not $driverRoot) {
        Start-Sleep 2
    }
}

if ($driverRoot) {
    # Install all .inf files from the drivers directory (NetKVM + viostor)
    Get-ChildItem -Path $driverRoot -Recurse -Filter *.inf | ForEach-Object {
        Write-Host "Installing driver: $($_.FullName)"
        pnputil.exe /add-driver $_.FullName /install 2>&1 | Out-Null
    }
    Write-Host "Drivers installed."
} else {
    Write-Warning "drivers directory not found on D:..I: after 90s — driver install skipped (DriverPaths should have staged them)"
}

Write-Host "Bootstrap complete."
