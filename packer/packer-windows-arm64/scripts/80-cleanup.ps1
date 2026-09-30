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

# DISM component cleanup
Write-Host "Running DISM cleanup..."
dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase

# Zero free space for qcow2 compaction - WITH A SAFETY MARGIN. The old
# version filled the disk to 100% and relied on a silently-suppressed
# Remove-Item to give the space back; on 2026-09-30 the guest reported 0%
# free during sysprep, sysprep never completed, and the build timed out
# waiting for the machine to shut down. Stop with a few GB free instead:
# the compaction penalty is negligible and the pagefile/NTFS/sysprep all
# keep working headroom.
Write-Host "Zeroing free space for qcow2 compaction..."
$marginBytes = 4GB
$zeroFile = "C:\zero.tmp"
$chunkSize = 16MB
$buffer = New-Object byte[] $chunkSize
$stream = $null
try {
    $stream = [System.IO.File]::OpenWrite($zeroFile)
    while ((Get-PSDrive -Name C).Free -gt $marginBytes) {
        $stream.Write($buffer, 0, $chunkSize)
    }
} catch {
    Write-Host "Zeroing stopped early: $($_.Exception.Message)"
} finally {
    if ($stream) { $stream.Dispose() }
    # The delete is NOT silently suppressed: if it fails, the pipeline
    # must fail loudly here instead of letting sysprep starve later.
    Remove-Item $zeroFile -Force -ErrorAction Stop
}

# Hard gates before handing off to sysprep (90-sysprep.ps1 / Sysprep.exe
# both need scratch space; fail HERE, loudly, not 30 minutes later).
if (Test-Path $zeroFile) {
    throw "Zero file still exists after cleanup: $zeroFile"
}
$freeGB = [math]::Round((Get-PSDrive -Name C).Free / 1GB, 1)
Write-Host "Free space after cleanup: $freeGB GB"
if ($freeGB -lt 2) {
    throw "Only $freeGB GB free after cleanup - refusing to hand off to sysprep"
}

Write-Host "Cleanup complete."
