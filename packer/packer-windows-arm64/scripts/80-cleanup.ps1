$ErrorActionPreference = 'SilentlyContinue'

Write-Host "Cleaning up temporary files..."

# Clear Windows Temp, but keep Packer's own session files (the env-vars
# helpers packer-ps-env-vars-*.ps1 live here mid-pipeline; wiping them broke
# the next session's env-var load - observed 2026-09-30).
Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -Exclude "packer-*" -ErrorAction SilentlyContinue
Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue

# Clear user temp
Remove-Item -Path "C:\Users\*\AppData\Local\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

# Clear Windows Update download cache
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Remove-Item -Path "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
Start-Service -Name wuauserv -ErrorAction SilentlyContinue

# Clear prefetch
Remove-Item -Path "C:\Windows\Prefetch\*" -Force -ErrorAction SilentlyContinue

# DISM StartComponentCleanup /ResetBase is REMOVED (2026-09-30): it took
# 47+ minutes via the elevated scheduled task on emulated ARM64 (vs ~10 min
# in prior non-elevated runs) and stalled the build at "Cleaning up
# temporary files..." while the guest sat idle. It is purely an image-size
# optimization - sysprep does not depend on it. The host-side post-build
# qemu-img convert to VMDK with subformat=streamOptimized handles image
# size. Re-add it only after profiling why it stalls in the elevated
# context on this hardware.

# Free-space zeroing is REMOVED (2026-09-30). Writing zeros until the
# disk is full starved sysprep and shutdown of scratch space (registry
# flushes, event logs, pagefile writes) - the guest sat at 0% free during
# sysprep, sysprep never completed, and the build timed out waiting for
# the machine to shut down. Image compaction is left to the host-side
# post-build step instead: the README's qemu-img convert to VMDK with
# subformat=streamOptimized is already a compressed format, so freed
# blocks cost little there without ever filling the guest disk.

# Pre-sysprep sanity gate (90-sysprep.ps1 gates the same way): report
# free space and refuse to hand off if the disk is dangerously full -
# Sysprep.exe needs scratch space; fail HERE, loudly, in seconds, not
# after the shutdown timeout.
$freeGB = [math]::Round((Get-PSDrive -Name C).Free / 1GB, 1)
Write-Host "Free space after cleanup: $freeGB GB"
if ($freeGB -lt 2) {
    throw "Only $freeGB GB free after cleanup - refusing to hand off to sysprep"
}

Write-Host "Cleanup complete."
