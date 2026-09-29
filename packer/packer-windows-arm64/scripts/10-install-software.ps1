$ErrorActionPreference = 'Stop'

# Software installs via winget (Windows Package Manager): winget selects
# the native ARM64 installer per package manifest from
# https://github.com/microsoft/winget-pkgs, and the VM pulls payloads over
# HTTPS in minutes (the old WinRM file upload of bundled installers moved
# ~100MB at ~30KB/s; the released Chocolatey CLI also lacks reliable
# ARM64 architecture selection).
#
# winget availability: on this unattended image App Installer is not
# necessarily ready in the provisioning session right after first logon
# (observed 2026-09-29: 'winget (App Installer) not found'). Two layers:
#   1. Wait up to 10 minutes - Windows provisions Store apps (including
#      App Installer) asynchronously after first logon.
#   2. If still missing, bootstrap from the pinned winget-cli release:
#      per-user Add-AppxPackage (so this build can use it now) plus
#      machine-wide Add-AppxProvisionedPackage with the offline license
#      (so users of the golden image get winget at their first logon).
#
# Pipeline position matters: this runs as the first powershell provisioner,
# after WinRM connects and before 40-validate-image.ps1 and 90-sysprep.ps1.

$wingetDir = "$env:LOCALAPPDATA\Microsoft\WindowsApps"

function Test-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }
    return (Test-Path "$wingetDir\winget.exe")
}

Write-Host 'Waiting for winget (App Installer) to become available...'
$deadline = (Get-Date).AddMinutes(10)
while (-not (Test-Winget) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 30
}

if (-not (Test-Winget)) {
    Write-Host 'winget not provisioned yet - bootstrapping App Installer...'

    # Pinned release; asset layout verified 2026-09-29:
    #   Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle is
    #   multi-arch, and the dependencies zip has an arm64/ folder with
    #   the three ARM64 dependency appx files this image needs.
    $release = 'https://github.com/microsoft/winget-cli/releases/download/v1.29.290'
    $work = "$env:TEMP\winget-bootstrap"
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $ProgressPreference = 'SilentlyContinue'
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

    $bundle = "$work\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
    Invoke-WebRequest -Uri "$release/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" -OutFile $bundle

    $depsZip = "$work\DesktopAppInstaller_Dependencies.zip"
    Invoke-WebRequest -Uri "$release/DesktopAppInstaller_Dependencies.zip" -OutFile $depsZip
    Expand-Archive -Path $depsZip -DestinationPath "$work\deps" -Force
    $deps = @(Get-ChildItem -Path "$work\deps\arm64" -Filter *.appx | ForEach-Object { $_.FullName })
    if ($deps.Count -eq 0) {
        throw 'No ARM64 dependency appx files found in DesktopAppInstaller_Dependencies.zip'
    }

    $license = "$work\License1.xml"
    Invoke-WebRequest -Uri "$release/e53e159d00e04f729cc2180cffd1c02e_License1.xml" -OutFile $license

    # Register for the current user so this build can use winget now.
    Add-AppxPackage -Path $bundle -DependencyPath $deps

    # Provision machine-wide so users of the golden image get winget too.
    Add-AppxProvisionedPackage -Online -Path $bundle -DependencyPath $deps -LicensePath $license | Out-Null
}

$env:Path += ";$wingetDir"

if (-not (Test-Winget)) {
    throw 'winget (App Installer) bootstrap failed'
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
