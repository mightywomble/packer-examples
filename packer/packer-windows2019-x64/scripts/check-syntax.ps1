# Host-side syntax gate: parse every build script with the PowerShell
# parser WITHOUT executing anything. Run before every build:
#   pwsh -NoProfile -File scripts/check-syntax.ps1
# Rationale (run 8, 2026-10-07): a parse error in 20-windows-updates.ps1
# ('\' inside a single-quoted string) made every update round silently do
# nothing - powershell.exe -File returns 0 for parse errors, so Packer
# accepted the "success" - and only the validation gate caught it after 45
# minutes. Parse here first; a 45-minute build must never be the thing that
# discovers a syntax error.

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$files = Get-ChildItem -Path $scriptDir -Filter '*.ps1' |
    Where-Object { $_.Name -ne 'check-syntax.ps1' } |
    Sort-Object Name

$failed = $false
foreach ($f in $files) {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $failed = $true
        Write-Host "FAIL $($f.Name):"
        foreach ($e in $errors) {
            Write-Host ("  line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message)
        }
    } else {
        Write-Host "OK   $($f.Name)"
    }
}

if ($failed) {
    throw 'PowerShell syntax check failed.'
}
Write-Host 'All provisioning scripts parse cleanly.'
