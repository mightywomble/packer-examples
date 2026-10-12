# Sysprep the image: /oobe /generalize /shutdown, launched detached.
# Invoked by the Packer shutdown_command, so it is the last code the build
# runs inside the guest. Adapted from the ARM64 project's 90-sysprep.ps1:
#   - free-space gate BEFORE starting sysprep (sysprep hangs forever on a
#     nearly-full disk; the ARM64 project burned a 30m timeout on exactly
#     that, 2026-09-30)
#   - launch via WMI Win32_Process.Create so Sysprep.exe lands in the WMI
#     service's own process tree, fully detached from the WinRM session /
#     scheduled task that started it. Earlier attempts on ARM64 showed
#     Start-Process-based launches get killed or take WinRM down with them.
#   - Windows Server has no per-user winget/appx packages, so the appx
#     removal from the ARM64 script is not needed here.

$ErrorActionPreference = 'Stop'

$sysprep = Join-Path $env:WINDIR 'System32\Sysprep\Sysprep.exe'

if (-not (Test-Path $sysprep)) {
    throw "Sysprep was not found: $sysprep"
}

$freeGB = [math]::Round((Get-PSDrive -Name C).Free / 1GB, 1)
if ($freeGB -lt 2) {
    throw "Only $freeGB GB free - sysprep needs scratch space; aborting"
}

# Template hygiene: force the built-in Administrator password to be changed
# at the first interactive logon of any machine cloned from this template
# (the same behaviour factory Windows Server images ship with). The build
# password must not silently persist into every deployment.
#
# Doing it HERE is safe because this script already runs inside the final
# authenticated WinRM session - the flag only affects later network logons.
Write-Host "Flagging Administrator password for change at next logon..."
net user Administrator /logonpasswordchg:yes

Write-Host "Running Sysprep to generalize the image..."
$result = Invoke-CimMethod `
    -ClassName Win32_Process `
    -MethodName Create `
    -Arguments @{ CommandLine = "`"$sysprep`" /oobe /generalize /shutdown /quiet" }

if ($result.ReturnValue -ne 0) {
    throw "Win32_Process.Create failed to launch Sysprep.exe (return code $($result.ReturnValue))"
}

Write-Host "Sysprep.exe launched via WMI (PID $($result.ProcessId)) - fully detached. The machine will shut down when it completes."

exit 0
