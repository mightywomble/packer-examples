$ErrorActionPreference = 'Stop'

# OpenSSH Client and Server via Windows capabilities
$capabilities = @(
    'OpenSSH.Client~~~~0.0.1.0',
    'OpenSSH.Server~~~~0.0.1.0'
)

foreach ($capability in $capabilities) {
    $state = Get-WindowsCapability -Online -Name $capability

    if ($state.State -ne 'Installed') {
        Write-Host "Installing $capability..."
        Add-WindowsCapability -Online -Name $capability
    }
}

# Enable and start SSH daemon
Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd

# Enable Remote Desktop
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
netsh advfirewall firewall set rule group="Remote Desktop" new enable=yes

# Ensure Windows Defender real-time protection is enabled
Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue

# Set event log maximum sizes to 512 MB
wevtutil sl Security /ms:524288
wevtutil sl System /ms:524288
wevtutil sl Application /ms:524288
