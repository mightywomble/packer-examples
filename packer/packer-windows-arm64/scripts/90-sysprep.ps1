$ErrorActionPreference = 'Stop'

$sysprep = Join-Path $env:WINDIR 'System32\Sysprep\Sysprep.exe'

if (-not (Test-Path $sysprep)) {
    throw "Sysprep was not found: $sysprep"
}

# Sysprep needs scratch space; fail loudly BEFORE starting it rather than
# hanging mid-generalize (observed 2026-09-30: sysprep never completed on a
# 0%-free disk and the build timed out waiting for the machine to shut
# down; 80-cleanup.ps1 gates the same way before handing off).
$freeGB = [math]::Round((Get-PSDrive -Name C).Free / 1GB, 1)
if ($freeGB -lt 2) {
    throw "Only $freeGB GB free - sysprep needs scratch space; aborting"
}

# Remove user-level appx packages that block sysprep /generalize.
# SysprepGeneralizeValidate (AppxSysprep.dll) requires ALL appx packages
# to be provisioned machine-wide; the winget source package
# (Microsoft.Winget.Source) is installed per-user when winget runs during
# provisioning and is NOT provisioned, causing sysprep to fail with
# 0x80073cf2 (observed 2026-09-30, confirmed via Panther setuperr.log:
# "Package ... was installed for a user, but not provisioned for all
# users ... halting sysprep execution"). Removing the per-user copy
# unblocks generalize; deployed images re-add winget sources on first use.
Write-Host "Removing per-user winget source package (sysprep generalize blocker)..."
Get-AppxPackage -Name "Microsoft.Winget.Source*" -ErrorAction SilentlyContinue |
    Remove-AppxPackage -ErrorAction SilentlyContinue

# Launch Sysprep asynchronously (no -Wait) so the WinRM shutdown command
# returns to Packer cleanly, BUT verify it actually started before exiting.
#
# -Wait removal alone was not enough (observed 2026-09-30, second attempt):
# the elevated provisioner runs this script via a scheduled task, and
# when the script exits immediately after Start-Process, Windows kills
# the scheduled task's process tree including the just-launched
# Sysprep.exe - the process died before writing any Panther logs, and
# the build sat waiting for a shutdown that never came.
#
# The fix: use -PassThru to get the process object, sleep briefly to let
# Sysprep.exe initialize and detach from the scheduled task's job, then
# verify it has not exited before returning. Fast enough for Packer's
# shutdown command (returns in ~10 seconds), with verification.
Write-Host "Running Sysprep to generalize the image..."
$proc = Start-Process `
    -FilePath $sysprep `
    -ArgumentList '/oobe /generalize /shutdown /quiet' `
    -PassThru

# Give Sysprep.exe time to initialize and create its log files before
# the scheduled task's process tree is cleaned up.
Start-Sleep -Seconds 10

if ($proc.HasExited) {
    throw "Sysprep.exe exited prematurely (exit code $($proc.ExitCode)) - it was likely killed by the scheduled task process tree cleanup"
}

Write-Host "Sysprep.exe is running (PID $($proc.Id)) - the machine will shut down when it completes."

exit 0
