# One round of Windows Update patching, reboot-aware and module-free.
# The build pipeline runs this three times, each followed by a reboot
# (provisioner "windows-restart"). Rounds are needed because Servicing Stack
# updates unlock further cumulative updates and some packages only appear
# after a reboot; the final round converges to "no updates available", and
# 40-validate-image.ps1 fails the build if anything is still pending.
#
# Run 5 (2026-10-07) exposed the original PSWindowsUpdate design: round 1
# downloaded and staged a large LCU, set the pending-reboot flags, and then
# hung ~55 min in TLS/PSGallery setup at the start of round 2 - on a machine
# that only needed a REBOOT, which the windows-restart provisioner would have
# done in seconds if this script had exited. The fix:
#   1. Reboot-pending check FIRST (registry RebootRequired keys, pending
#      file renames, hotfixes newer than boot time) - if pending, exit 0
#      immediately so the following windows-restart provisioner reboots
#      promptly.
#   2. Pending scan via the Windows Update Agent COM API (fast, no module).
#   3. Install via the same COM API - no PSWindowsUpdate/PSGallery/NuGet/TLS
#      dependency at all (that whole stack was the hang point).
# Uses only inbox Windows Server 2019 components.
#
# WU busy caveat: when the update session reports "another installation is
# in progress" (background WU worker still staging), we exit 0 and let the
# restart provisioner + next round settle it.

$ErrorActionPreference = 'Stop'

Write-Host "=== Windows Update round starting at $((Get-Date).ToUniversalTime().ToString('o')) ==="

# Run 6 (2026-10-07): round 3 was killed mid-download with scheduled-task
# exit code 0x41306 (SCHED_S_TASK_TERMINATED) - the WU agent force-rebooted
# the machine for updates staged by an earlier round, terminating this
# script's elevated task. The build owns ALL reboots (windows-restart
# provisioners), so tell the WU agent to never reboot on its own:
#   AUOptions=3 (download + notify; never auto-install/reboot)
#   NoAutoRebootWithLoggedOnUsers=1 (kept in the shipped template - never
#   force-reboot a machine with an admin logged on; AUOptions is reverted
#   by 80-cleanup.ps1 before shipping).
$auPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
reg add $auPolicy /v AUOptions /t REG_DWORD /d 3 /f | Out-Null
reg add $auPolicy /v NoAutoRebootWithLoggedOnUsers /t REG_DWORD /d 1 /f | Out-Null
Write-Host 'WU auto-reboot policies set (all reboots are owned by the pipeline).'

function Test-RebootPending {
    # 1) CBS/servicing stacks write these keys when a reboot is required.
    $keyPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    )
    foreach ($k in $keyPaths) {
        if (Test-Path $k) {
            Write-Host "Reboot pending: registry key $k"
            return $true
        }
    }

    # 2) PendingFileRenameOperations (pending renames never complete
    #    without a restart).
    $pfro = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
        -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($pfro -and $pfro.PendingFileRenameOperations) {
        Write-Host 'Reboot pending: PendingFileRenameOperations present'
        return $true
    }

    # 3) A hotfix installed after the last boot means its servicing is
    #    half-applied until reboot (observed on run 5: LCU completed staging,
    #    Get-HotFix already listed it, reboot still required).
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $bootTime = $os.LastBootUpTime
    $newer = Get-CimInstance -ClassName Win32_QuickFixEngineering |
        Where-Object { $_.InstalledOn -and $_.InstalledOn -gt $bootTime }
    if ($newer) {
        $ids = ($newer | ForEach-Object { $_.HotFixID }) -join ', '
        Write-Host "Reboot pending: hotfix(es) installed after last boot: $ids"
        return $true
    }

    return $false
}

# --- Step 1: nothing matters more than rebooting a half-patched machine ---
if (Test-RebootPending) {
    Write-Host 'Updates are staged/half-applied and a restart is required. Exiting so the windows-restart provisioner reboots the machine promptly.'
    exit 0
}

# --- Step 2: scan for applicable updates via the WU COM API ---
Write-Host 'Searching for applicable updates (Windows Update Agent COM)...'
$session = New-Object -ComObject Microsoft.Update.Session
$searcher = $session.CreateUpdateSearcher()

try {
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0")
} catch {
    $msg = $_.Exception.Message
    Write-Host "Update search failed: $msg"
    if ($msg -like '*in progress*' -or $msg -like '*0x8024*' -or $msg -like '*busy*') {
        Write-Host 'Another WU operation is in progress (likely staging from the previous round). Exiting for the restart provisioner to settle it.'
        exit 0
    }
    throw "Update search failed: $msg"
}

Write-Host "Search complete: $($result.Updates.Count) applicable update(s)."

if ($result.Updates.Count -eq 0) {
    Write-Host 'No Windows updates are currently available - round converged.'
    exit 0
}

$updates = @($result.Updates)
$kbList = ($updates | ForEach-Object { $_.KBArticleIDs | Select-Object -First 1 }) -join ', '
$downloadSize = ($updates | Measure-Object -Property MaxDownloadSize -Sum).Sum / 1MB
Write-Host ("Installing {0} update(s) ({1:N0} MB): {2}" -f $updates.Count, $downloadSize, $kbList)

# --- Step 3: download ---
$coll = New-Object -ComObject Microsoft.Update.UpdateColl
foreach ($u in $updates) {
    if (-not $u.EulaAccepted) {
        try { $u.AcceptEula() } catch { Write-Host "Could not accept EULA for $($u.Title)" }
    }
    if ($u.InstallationBehavior.CanRequestUserInput) {
        Write-Host "Skipping (requires user input): $($u.Title)"
        continue
    }
    $null = $coll.Add($u)
}
if ($coll.Count -eq 0) {
    Write-Host 'No installable updates after filtering.'
    exit 0
}
# Re-check reboot-pending immediately before the long operations: the
# search itself takes minutes and CBS can set reboot flags meanwhile (the
# exact window in which run 6 was killed). If anything says restart now,
# hand off to the restart provisioner instead of racing it.
if (Test-RebootPending) {
    Write-Host 'Reboot became pending during the search. Exiting so the windows-restart provisioner reboots the machine promptly.'
    exit 0
}

$downloader = $session.CreateUpdateDownloader()
$downloader.Updates = $coll

Write-Host 'Downloading...'
$dlResult = $downloader.Download()
Write-Host ("Download result code: {0} (2=Succeeded)" -f $dlResult.ResultCode)
if ($dlResult.ResultCode -notin 2, 3) {
    throw "Update download failed with result code $($dlResult.ResultCode)"
}

# --- Step 4: install ---
$installer = $session.CreateUpdateInstaller()
$installer.Updates = $coll
Write-Host 'Installing...'
$instResult = $installer.Install()
Write-Host ("Install result code: {0} (2=Succeeded, 3=SucceededWithErrors)" -f $instResult.ResultCode)
Write-Host ("Reboot required after install: {0}" -f $instResult.RebootRequired)

if ($instResult.RebootRequired) {
    Write-Host 'Updates applied - restart required. Exiting so the windows-restart provisioner reboots the machine.'
    exit 0
}

if ($instResult.ResultCode -notin 2, 3) {
    throw "Windows Update install failed with result code $($instResult.ResultCode)"
}

Write-Host '=== Windows Update round complete ==='
exit 0
