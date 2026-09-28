$ErrorActionPreference = 'Stop'

$SoftwareRoot = 'C:\Windows\Temp\software'

$SevenZip   = Join-Path $SoftwareRoot '7zip-arm64.exe'
$PowerShell = Join-Path $SoftwareRoot 'powershell-arm64.msi'

if (-not (Test-Path $SevenZip)) {
    throw "7-Zip installer not found: $SevenZip"
}

if (-not (Test-Path $PowerShell)) {
    throw "PowerShell installer not found: $PowerShell"
}

Write-Host "Installing 7-Zip..."
$sevenZipProcess = Start-Process `
    -FilePath $SevenZip `
    -ArgumentList '/S' `
    -Wait `
    -PassThru

if ($sevenZipProcess.ExitCode -ne 0) {
    throw "7-Zip installation failed: $($sevenZipProcess.ExitCode)"
}

Write-Host "Installing PowerShell 7..."
$powerShellProcess = Start-Process `
    -FilePath 'msiexec.exe' `
    -ArgumentList "/i `"$PowerShell`" /qn /norestart" `
    -Wait `
    -PassThru

if ($powerShellProcess.ExitCode -notin 0, 3010) {
    throw "PowerShell installation failed: $($powerShellProcess.ExitCode)"
}

Write-Host "Software installation complete."
