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

Write-Host "Running Sysprep to generalize the image..."
Start-Process `
    -FilePath $sysprep `
    -ArgumentList '/oobe /generalize /shutdown /quiet' `
    -Wait

exit 0
