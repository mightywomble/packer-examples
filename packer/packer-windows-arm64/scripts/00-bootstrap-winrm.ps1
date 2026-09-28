# Bootstrap WinRM so Packer can communicate with the building VM.
# Runs as a FirstLogonCommand via Autounattend.xml.

$ErrorActionPreference = 'Stop'

Write-Host "Configuring WinRM for Packer communication..."

# Enable WinRM service
winrm quickconfig -q

# Increase timeout for slow builds
winrm set winrm/config '@{MaxTimeoutms="1800000"}'

# Allow unencrypted and Basic auth (Packer defaults for Windows)
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/client '@{AllowUnencrypted="true"}'
winrm set winrm/config/client/auth '@{Basic="true"}'

# Open firewall for WinRM HTTP on port 5985
netsh advfirewall firewall set rule group="Windows Remote Management" new enable=yes
netsh advfirewall firewall add rule name="WinRM-HTTP" dir=in action=allow protocol=TCP localport=5985

# Set WinRM service to auto-start
sc.exe config WinRM start= auto

# Restart to apply
Restart-Service -Name WinRM -Force

Write-Host "WinRM configured successfully."
