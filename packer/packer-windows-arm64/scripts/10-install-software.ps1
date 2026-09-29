$ErrorActionPreference = 'Stop'

# Software installs via winget (Windows Package Manager) instead of
# Chocolatey: winget selects the native ARM64 installer per package
# manifest from https://github.com/microsoft/winget-pkgs, and the VM
# pulls payloads over HTTPS in minutes (the old WinRM file upload of
# bundled installers moved ~100MB at ~30KB/s; the released Chocolatey
# CLI also lacks reliable ARM64 architecture selection).
#
# Pipeline position matters: this runs as the first powershell provisioner,
# after WinRM connects (network and PnP settled at first logon - NOT during
# the specialize pass, which is fragile mid-device-install) and before
# 40-validate-image.ps1 (which checks these apps landed) and 90-sysprep.ps1
# (which generalizes them into the image).
#
# winget ships as "App Installer" on full Windows 11 editions and is
# available in the WinRM session. Clean or LTSC images without it would
# need the DesktopAppInstaller msixbundle (plus VCLibs/UI.Xaml ARM64
# dependencies) bootstrapped first; this script fails loudly instead of
# guessing.

$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    throw 'winget (App Installer) not found - bootstrap the msixbundle before provisioning'
}
winget --version

# Native-ARM64 example packages from microsoft/winget-pkgs. To install
# other software, add its exact ID to this list - e.g. 'Google.Chrome'
# or 'Notepad++.Notepad++'.
$packages = @(
    'Git.Git',
    '7zip.7zip'
)

foreach ($pkg in $packages) {
    Write-Host "Installing $pkg ..."
    winget install --id $pkg --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -notin 0, 3010) {
        throw "$pkg installation failed: $LASTEXITCODE"
    }
}

Write-Host 'Software installation complete.'
