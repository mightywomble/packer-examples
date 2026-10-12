# Validation gate for the Windows Server 2019 x64 template.
# Mirrors the repo's golden-image pattern: hard assertions fail the build,
# everything interesting is recorded to C:\ImageBuild\validation-report.json
# (which the build downloads into reports/ as release evidence).

$ErrorActionPreference = 'Stop'

Write-Host "Collecting golden-image validation evidence..."

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$cv  = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

# Pending updates via the Windows Update Agent COM API - the build no
# longer uses PSWindowsUpdate anywhere (see 20-windows-updates.ps1).
$wuSession = New-Object -ComObject Microsoft.Update.Session
$wuSearcher = $wuSession.CreateUpdateSearcher()
$wuResult = $wuSearcher.Search("IsInstalled=0 and IsHidden=0")
$pending = @($wuResult.Updates)

# Half-applied servicing at validation time is evidence the image is not
# settled; recorded in the report (hard gate stays on FullyPatched).
$rebootPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')

$hotfixes = Get-HotFix | Sort-Object -Property InstalledOn -Descending
$lastHotfix = $hotfixes | Select-Object -First 1

$gaVersion = (Get-ItemProperty `
        -Path 'HKLM:\SOFTWARE\Oracle\VirtualBox Guest Additions' `
        -ErrorAction SilentlyContinue).Version

$results = [ordered]@{
    TimestampUtc           = (Get-Date).ToUniversalTime().ToString('o')
    ImageVersion           = $env:IMAGE_VERSION
    Architecture           = $env:PROCESSOR_ARCHITECTURE
    OsCaption              = $os.Caption
    OsVersion              = $os.Version
    Build                  = "$($cv.CurrentBuildNumber).$($cv.UBR)"
    IsWindowsServer2019    = $os.Caption -like '*Windows Server 2019*'
    GuestAdditionsVersion  = $gaVersion
    GuestAdditionsInstalled = [bool]$gaVersion
    PendingUpdateCount     = $pending.Count
    PendingUpdateKbs       = (($pending | ForEach-Object { $_.KBArticleIDs | Select-Object -First 1 }) -join ', ')
    FullyPatched           = ($pending.Count -eq 0)
    RebootPending          = [bool]$rebootPending
    InstalledHotfixCount   = @($hotfixes).Count
    LastHotfixId           = $lastHotfix.HotFixID
    LastHotfixInstalledOn  = $lastHotfix.InstalledOn
    FreeSpaceGB            = [math]::Round((Get-PSDrive -Name C).Free / 1GB, 1)
}

$reportDirectory = 'C:\ImageBuild'
New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null

$results |
    ConvertTo-Json -Depth 4 |
    Set-Content "$reportDirectory\validation-report.json"

# Hard gates: anything false here fails the build loudly.
$failed = $results.GetEnumerator() | Where-Object {
    $_.Key -in @(
        'IsWindowsServer2019',
        'GuestAdditionsInstalled',
        'FullyPatched'
    ) -and
    $_.Value -ne $true
}

if ($failed) {
    $failed | Format-Table -AutoSize | Out-String | Write-Error
    throw 'Golden-image validation failed.'
}

Write-Host ("Validation passed: {0} (build {1}), Guest Additions {2}, " +
    "{3} hotfixes installed, 0 pending updates." -f `
    $results.OsCaption, $results.Build, $results.GuestAdditionsVersion, `
    $results.InstalledHotfixCount)
