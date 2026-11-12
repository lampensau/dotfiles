# Run by bootstrap.ps1 in one elevated process: Win11Debloat (optional), then the OpenSSH agent service.
# Bitwarden: the SSH agent needs the Windows "OpenSSH Authentication Agent" service disabled.
param(
    [string]$Debloat,
    [string]$Config
)
$ErrorActionPreference = 'Stop'
$rc = 0
try {
    if ($Debloat) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Debloat -Config $Config -Silent
        $rc = $LASTEXITCODE
    }
    $svc = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
    if ($svc) {
        Stop-Service -Name ssh-agent -Force
        Set-Service -Name ssh-agent -StartupType Disabled
    }
}
catch {
    Write-Output "elevated step failed: $_"
    $rc = 1
}
if ($rc -ne 0) { Read-Host 'Failed. Press Enter to close' | Out-Null }
exit $rc
