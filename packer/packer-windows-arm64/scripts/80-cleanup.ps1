$ErrorActionPreference = 'SilentlyContinue'

Write-Host "Cleaning up temporary files..."

# Clear Windows Temp
Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
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

# Zero free space to optimize qcow2 compaction
Write-Host "Zeroing free space for qcow2 compaction..."
$zeroFile = "C:\zero.tmp"
$chunkSize = 1MB
$buffer = New-Object byte[] $chunkSize
try {
    $stream = [System.IO.File]::OpenWrite($zeroFile)
    while ($true) {
        $stream.Write($buffer, 0, $chunkSize)
    }
} catch {
    # Disk is full — expected
} finally {
    if ($stream) { $stream.Dispose() }
    Remove-Item $zeroFile -Force -ErrorAction SilentlyContinue
}

Write-Host "Cleanup complete."
