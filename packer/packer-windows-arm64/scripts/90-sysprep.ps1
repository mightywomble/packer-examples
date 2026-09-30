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

# Launch Sysprep via WMI process creation (Win32_Process.Create). This
# creates the process in the WMI service's own context (running as
# SYSTEM in its own process tree), completely detached from this
# script's scheduled-task process tree.
#
# Previous attempts (observed 2026-09-30, three runs):
#   1. Start-Process -Wait: WinRM drops mid-shutdown, Packer errors
#      ("Failed to send shutdown command ... EOF")
#   2. Start-Process without -Wait: sysprep killed before writing any
#      Panther logs (immediate process-tree cleanup)
#   3. Start-Process -PassThru + 10s sleep: sysprep started, wrote 57 KB
#      of Panther log entries, executed ~50 providers, then was killed
#      mid-flight during GeneralizeForImaging (usosvc.dll) - the
#      scheduled task cleanup reached it asynchronously
#
# WMI Win32_Process.Create is the only launch method that puts Sysprep.exe
# in a completely independent process tree that no scheduled-task
# cleanup can touch.
Write-Host "Running Sysprep to generalize the image..."
$result = Invoke-CimMethod `
    -ClassName Win32_Process `
    -MethodName Create `
    -Arguments @{ CommandLine = "`"$sysprep`" /oobe /generalize /shutdown /quiet" }

if ($result.ReturnValue -ne 0) {
    throw "Win32_Process.Create failed to launch Sysprep.exe (return code $($result.ReturnValue))"
}

Write-Host "Sysprep.exe launched via WMI (PID $($result.ProcessId)) - fully detached from the scheduled task. The machine will shut down when it completes."

exit 0
