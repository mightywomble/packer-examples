# Install VirtualBox Guest Additions from the GA ISO that the builder
# attached (guest_additions_mode = "attach"). A template without Guest
# Additions has no display auto-resize, shared folders, clipboard or host
# time sync, so this runs first in the provisioning pipeline.
#
# Any required reboot is absorbed by the Windows Update restart that
# follows this script in the pipeline (installer exit code 3010).

$ErrorActionPreference = 'Stop'

Write-Host "Locating Guest Additions CD..."

# The GA volume label looks like "VBox_GAs_7.2.20" (version-tagged).
$gaVolume = Get-Volume |
    Where-Object { $_.FileSystemLabel -like 'VBox_GAs*' } |
    Select-Object -First 1

if (-not $gaVolume) {
    # Re-scan with a short wait: CD drive letters can lag a few seconds
    # behind WinRM coming up (same lesson as the unattend CD bootstrap).
    for ($i = 0; $i -lt 30 -and -not $gaVolume; $i++) {
        Start-Sleep -Seconds 2
        $gaVolume = Get-Volume |
            Where-Object { $_.FileSystemLabel -like 'VBox_GAs*' } |
            Select-Object -First 1
    }
}

if (-not $gaVolume) {
    throw "Guest Additions CD (VBox_GAs*) not found after 60s"
}

$gaRoot = "$($gaVolume.DriveLetter):\"
Write-Host "Guest Additions CD found at $gaRoot (label: $($gaVolume.FileSystemLabel))"

# Trust the GA signing certs first: silent driver installs fail without
# the cert in Trusted Publisher/Root. GA ships VBoxCertUtil + sha1/sha256
# certs; guard each file so older/newer GA layouts do not break the script.
$certDir = Join-Path $gaRoot 'cert'
if (Test-Path $certDir) {
    $certUtil = Join-Path $certDir 'VBoxCertUtil.exe'
    if (Test-Path $certUtil) {
        foreach ($cer in @('vbox-sha256.cer', 'vbox-sha1.cer')) {
            $cerPath = Join-Path $certDir $cer
            if (Test-Path $cerPath) {
                Write-Host "Trusting GA certificate: $cer"
                # VBoxCertUtil 7.2.20 verbs are add-root / add-trusted-publisher
                # (run 8 showed plain 'add' is rejected). Best-effort: the GA
                # driver install succeeds via trusted-publisher alone.
                & $certUtil add-root $cerPath 2>&1 | Out-Null
                & $certUtil add-trusted-publisher $cerPath 2>&1 | Out-Null
            }
        }
    }
} else {
    Write-Warning "No cert directory on GA media - driver signing may not be pre-trusted"
}

Write-Host "Installing VirtualBox Guest Additions (silent)..."
$installer = Join-Path $gaRoot 'VBoxWindowsAdditions.exe'
if (-not (Test-Path $installer)) {
    throw "VBoxWindowsAdditions.exe not found at $installer"
}

$proc = Start-Process -FilePath $installer -ArgumentList '/S' -Wait -PassThru

# 0 = success, 3010 = success, reboot required (covered by the update
# round restart that follows in the pipeline).
if ($proc.ExitCode -notin 0, 3010) {
    throw "Guest Additions install failed with exit code $($proc.ExitCode)"
}

Write-Host "Guest Additions installed (exit code $($proc.ExitCode))."

# Record the version for the validation report / image evidence.
$gaVersion = (Get-ItemProperty `
        -Path 'HKLM:\SOFTWARE\Oracle\VirtualBox Guest Additions' `
        -ErrorAction SilentlyContinue).Version
Write-Host "Installed Guest Additions version: $gaVersion"

exit 0
