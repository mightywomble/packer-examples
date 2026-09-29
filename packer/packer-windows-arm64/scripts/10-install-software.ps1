$ErrorActionPreference = 'Stop'

# Software installs via Chocolatey instead of uploading bundled installers:
# the WinRM file provisioner moves ~100MB installers at ~30KB/s (an hour or
# more), while the VM pulls the same packages over HTTPS in minutes. The
# slirp network is proven (Windows Update pulls GBs through it during setup).
#
# Pipeline position matters: this runs as the first powershell provisioner,
# after WinRM connects (network and PnP settled at first logon - NOT during
# the specialize pass, which is fragile mid-device-install) and before
# 40-validate-image.ps1 (which checks these apps landed) and 90-sysprep.ps1
# (which generalizes them into the image).
#
# ARM64 note: Chocolatey itself runs natively. Some packages (e.g. Chrome)
# may deliver the x64 build, which Windows 11 ARM64 runs under x64
# emulation.

Write-Host "Installing Chocolatey..."
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# The installer updates PATH for future sessions only; refresh it here so
# choco is callable in this same session.
if (-not (Test-Path 'C:\ProgramData\chocolatey\bin\choco.exe')) {
    throw 'Chocolatey installation failed: choco.exe not found'
}
$env:Path += ';C:\ProgramData\chocolatey\bin'
choco --version

Write-Host "Installing Google Chrome..."
choco install googlechrome -y --no-progress
if ($LASTEXITCODE -notin 0, 1641, 1642, 3010) {
    throw "Google Chrome installation failed: $LASTEXITCODE"
}

Write-Host "Installing Notepad++..."
choco install notepadplusplus.install -y --no-progress
if ($LASTEXITCODE -notin 0, 1641, 1642, 3010) {
    throw "Notepad++ installation failed: $LASTEXITCODE"
}

Write-Host "Software installation complete."
