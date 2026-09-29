$ErrorActionPreference = 'Stop'

$results = [ordered]@{
    TimestampUtc             = (Get-Date).ToUniversalTime().ToString('o')
    Architecture             = $env:PROCESSOR_ARCHITECTURE
    GitInstalled             = Test-Path 'C:\Program Files\Git\bin\git.exe'
    SevenZipInstalled        = Test-Path 'C:\Program Files\7-Zip\7z.exe'
    OpenSshServerInstalled   = (
        Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    ).State -eq 'Installed'
    ScriptBlockLogging       = $false
    SmbV1Disabled            = $false
    GuestDisabled            = $false
}

$scriptLoggingPath =
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'

if (Test-Path $scriptLoggingPath) {
    $results.ScriptBlockLogging =
        (Get-ItemProperty $scriptLoggingPath).EnableScriptBlockLogging -eq 1
}

$smbState = Get-WindowsOptionalFeature `
    -Online `
    -FeatureName SMB1Protocol `
    -ErrorAction SilentlyContinue

$results.SmbV1Disabled = $smbState.State -ne 'Enabled'

$guest = Get-LocalUser -Name Guest -ErrorAction SilentlyContinue
$results.GuestDisabled = $null -eq $guest -or -not $guest.Enabled

$reportDirectory = 'C:\ImageBuild'
New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null

$results |
    ConvertTo-Json -Depth 4 |
    Set-Content "$reportDirectory\validation-report.json"

$failed = $results.GetEnumerator() | Where-Object {
    $_.Key -notin 'TimestampUtc', 'Architecture' -and
    $_.Value -ne $true
}

if ($failed) {
    $failed | Format-Table -AutoSize | Out-String | Write-Error
    throw 'Golden-image validation failed.'
}

Write-Host 'All golden-image validation tests passed.'
