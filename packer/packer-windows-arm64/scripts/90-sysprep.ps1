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

Write-Host "Running Sysprep to generalize the image..."
Start-Process `
    -FilePath $sysprep `
    -ArgumentList '/oobe /generalize /shutdown /quiet' `
    -Wait

exit 0
