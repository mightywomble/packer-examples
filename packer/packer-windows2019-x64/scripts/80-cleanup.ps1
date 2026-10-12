# Pre-sysprep cleanup for the Windows Server 2019 x64 template.
# Adapted from the ARM64 project's 80-cleanup.ps1:
#   - temp clearing keeps Packer's own session files (packer-*) intact
#   - Windows Update cache clearing / DISM StartComponentCleanup / free-
#     space zeroing stay OUT (they stalled builds on the ARM64 project and
#     are image-size optimizations, not sysprep requirements)
#   - free-space gate: refuse to hand off to sysprep on a nearly-full disk

$ErrorActionPreference = 'SilentlyContinue'

Write-Host "Cleaning up temporary files..."

# Clear Windows Temp, but keep Packer's own session files (the env-vars
# helpers packer-ps-env-vars-*.ps1 live here mid-pipeline).
Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -Exclude "packer-*"
Remove-Item -Path "$env:TEMP\*" -Recurse -Force
Remove-Item -Path "C:\Users\*\AppData\Local\Temp\*" -Recurse -Force

# --- Firewall re-arm -------------------------------------------------------
# 00-bootstrap-winrm.ps1 disabled the firewall entirely for the build.
# The template must not ship that way. Re-arm it WITH a scoped WinRM rule
# first, so the remaining build steps (report download, sysprep upload and
# the shutdown command) still reach WinRM over the VirtualBox NAT network.
# 10.0.2.2 is the VirtualBox NAT gateway - the address WinRM traffic from
# the host always arrives from on any VirtualBox NAT host, so imported
# copies keep working over NAT; other network modes need their own rules.
Write-Host "Re-arming Windows Firewall with scoped WinRM rule..."
netsh advfirewall firewall delete rule name="WinRM HTTP-in (packer build)" | Out-Null
netsh advfirewall firewall add rule `
    name="WinRM HTTP-in (packer build)" `
    dir=in action=allow protocol=TCP localport=5985 remoteip=10.0.2.2 profile=any
netsh advfirewall set allprofiles state on

# --- Windows Update policy posture -----------------------------------------
# 20-windows-updates.ps1 sets AUOptions=3 during the build so the WU agent
# never auto-installs/auto-reboots mid-round. Shipped-template posture:
# revert AUOptions (deployers choose their own update policy), but keep
# NoAutoRebootWithLoggedOnUsers=1 - a server template should never force a
# reboot under a logged-on admin.
Write-Host "Restoring default WU policy (keep no-force-reboot)..."
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions /f 2>&1 | Out-Null

# --- Pre-sysprep sanity gate ------------------------------------------------
# Sysprep.exe needs scratch space; fail HERE, loudly, in seconds, not after
# the shutdown timeout (90-sysprep.ps1 gates the same way).
$freeGB = [math]::Round((Get-PSDrive -Name C).Free / 1GB, 1)
Write-Host "Free space after cleanup: $freeGB GB"
if ($freeGB -lt 2) {
    throw "Only $freeGB GB free after cleanup - refusing to hand off to sysprep"
}

Write-Host "Cleanup complete."
