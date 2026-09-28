$ErrorActionPreference = 'Stop'

$sysprep = Join-Path $env:WINDIR 'System32\Sysprep\Sysprep.exe'

if (-not (Test-Path $sysprep)) {
    throw "Sysprep was not found: $sysprep"
}

Write-Host "Running Sysprep to generalize the image..."
Start-Process `
    -FilePath $sysprep `
    -ArgumentList '/oobe /generalize /shutdown /quiet' `
    -Wait

exit 0
