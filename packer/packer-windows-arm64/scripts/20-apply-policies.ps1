$ErrorActionPreference = 'Stop'

function Set-PolicyDword {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [int]$Value
    )

    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty `
        -Path $Path `
        -Name $Name `
        -PropertyType DWord `
        -Value $Value `
        -Force | Out-Null
}

# PowerShell Script Block Logging
Set-PolicyDword `
    -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' `
    -Name 'EnableScriptBlockLogging' `
    -Value 1

# PowerShell Module Logging
Set-PolicyDword `
    -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging' `
    -Name 'EnableModuleLogging' `
    -Value 1

# Audit process creation with command line
Set-PolicyDword `
    -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit' `
    -Name 'ProcessCreationIncludeCmdLine_Enabled' `
    -Value 1

# Legal notice banner (string values, NOT DWORDs)
Set-ItemProperty `
    -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    -Name 'LegalNoticeCaption' `
    -Value 'Managed Golden Image'

Set-ItemProperty `
    -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    -Name 'LegalNoticeText' `
    -Value 'This system was built, configured and validated through the Packer image pipeline.'

# Disable SMBv1
Disable-WindowsOptionalFeature `
    -Online `
    -FeatureName SMB1Protocol `
    -NoRestart `
    -ErrorAction SilentlyContinue

# Enable audit policy for process creation
auditpol.exe /set `
    /subcategory:"Process Creation" `
    /success:enable `
    /failure:enable

# Disable Guest account
Disable-LocalUser -Name 'Guest' -ErrorAction SilentlyContinue

# Apply group policy
gpupdate.exe /force
