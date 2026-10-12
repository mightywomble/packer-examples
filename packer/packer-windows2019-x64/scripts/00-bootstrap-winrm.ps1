# Bootstrap WinRM so Packer can communicate with the building VM.
# Runs at first logon via Autounattend.xml FirstLogonCommands (a retrying
# waiter locates this script on the unattend CD). First logon is the ONLY
# safe place for this - the ARM64 project learned (2026-09-29) that
# enabling WinRM inline during the specialize pass crashes setup with the
# "computer restarted unexpectedly" reboot loop while devices are still
# installing; at first logon PnP and the network stack have settled.
#
# This is the x64/VirtualBox variant of the ARM64 bootstrap: no VirtIO
# driver staging is needed (VirtualBox presents an Intel e1000 NIC and
# SATA/IDE storage, all with inbox Windows Server 2019 drivers).

$ErrorActionPreference = 'Stop'

Write-Host "Configuring WinRM for Packer communication..."

# Network profile: deliberately left as-is (the VirtualBox NAT NIC lands as
# unidentified/Public). The template's chosen deployment behaviour is
# "No" to discoverability (= Public), confirmed 2026-10-07; the interactive
# prompt that would normally ask is suppressed machine-wide via the
# NewNetworkWindowOff registry value set in the specialize pass.
# Enable-PSRemoting -SkipNetworkProfileCheck below exists precisely to
# create the listener on a Public-profile adapter, so no profile change is
# needed for the build.

# Enable the WinRM listener on the Public-profile NAT adapter.
Enable-PSRemoting -Force -SkipNetworkProfileCheck

# For the build only: turn the firewall off entirely so nothing blocks
# inbound WinRM on 5985, regardless of network profile. 80-cleanup.ps1
# re-arms the firewall (with a NAT-scoped WinRM allow rule) before sysprep,
# so the shipped template does not keep a disabled firewall.
netsh advfirewall set allprofiles state off

# Allow unencrypted and Basic auth (Packer's default Windows transport).
Set-Item WSMan:\localhost\Service\AllowUnencrypted $true
Set-Item WSMan:\localhost\Service\Auth\Basic $true
Set-Item WSMan:\localhost\Client\AllowUnencrypted $true
Set-Item WSMan:\localhost\Client\Auth\Basic $true

# Increase timeout for slow builds
winrm set winrm/config '@{MaxTimeoutms="1800000"}'

# Ensure WinRM starts automatically and is running (survives the Windows
# Update reboots during provisioning without needing another logon).
sc.exe config WinRM start= auto
Restart-Service -Name WinRM -Force

Write-Host "WinRM configured successfully."
Write-Host "Bootstrap complete."
