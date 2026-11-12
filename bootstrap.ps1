# Fresh Windows 10/11 to an authenticated state, then hand over to the private dotfiles repo.
# Run as the normal user: powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
# Windows PowerShell 5.1 only features here (a fresh machine has nothing else; Win11Debloat refuses pwsh 7).
$ErrorActionPreference = 'Stop'

# Win11Debloat release 2026.10.30, Win11Debloat.zip (matches the release's SHA256SUMS).
$DebloatTag = '2026.10.30'
$DebloatSha256 = '6830bf501d2740c3317133ac0ecdc2a3ab80ed7f6c83e7f0f20dc66afbf758a7'
$WinSsh = 'C:\Windows\System32\OpenSSH'
$WinSshCommand = 'C:/Windows/System32/OpenSSH/ssh.exe'

function Read-YesNo([string]$Prompt, [bool]$Default) {
    $hint = '[y/N]'
    if ($Default) { $hint = '[Y/n]' }
    $answer = (Read-Host "$Prompt $hint").Trim()
    if ($answer -eq '') { return $Default }
    return ($answer -match '^y')
}

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE" }
}

# Windows PowerShell 5.1 turns redirected native stderr into a terminating error under 'Stop'.
# Output goes to the caller, stderr is dropped, the caller checks $LASTEXITCODE.
function Invoke-NativeQuiet([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    & $Exe @Arguments 2>$null
}

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Find-Installed($Package) {
    if ($Package.Command) {
        $cmd = Get-Command $Package.Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    foreach ($path in $Package.Paths) {
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    }
    return $null
}

# 1. winget
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Output 'winget is missing. It ships with the Microsoft "App Installer" package.'
    Write-Output 'Install or update App Installer from the Microsoft Store, open a new window, and run this script again.'
    exit 1
}

# 2. Packages
$packages = @(
    @{ Id = 'Git.Git'; Command = 'git' },
    @{ Id = 'Microsoft.PowerShell'; Command = 'pwsh' },
    @{ Id = 'twpayne.chezmoi'; Command = 'chezmoi' },
    @{ Id = 'Bitwarden.Bitwarden'; Paths = @("$env:LOCALAPPDATA\Programs\Bitwarden\Bitwarden.exe", "$env:ProgramFiles\Bitwarden\Bitwarden.exe") }
)
if ([Environment]::OSVersion.Version.Build -lt 22000) { $packages += @{ Id = 'Microsoft.WindowsTerminal'; Command = 'wt' } }
Update-SessionPath
foreach ($package in $packages) {
    $id = $package.Id
    $found = Find-Installed $package
    winget list --exact --id $id --accept-source-agreements | Out-Null
    $listed = ($LASTEXITCODE -eq 0)
    if ($found -or $listed) {
        Write-Output "$id is already installed"
        if ($found -and -not $listed) { Write-Output "warning: $id found at $found, not managed by winget" }
        continue
    }
    Invoke-Native winget @('install', '--exact', '--id', $id, '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements')
}
Update-SessionPath

# 3. Win11Debloat and the Windows OpenSSH agent service, in one elevated process
$markerDir = Join-Path $env:LOCALAPPDATA 'dotfiles-bootstrap'
$marker = Join-Path $markerDir 'win11debloat-last-run.txt'
if (Test-Path -LiteralPath $marker) {
    $lastRun = (Get-Content -LiteralPath $marker -TotalCount 1)
    $runDebloat = Read-YesNo "Win11Debloat last ran on $lastRun. Run it again?" $false
}
else {
    $runDebloat = Read-YesNo 'Run Win11Debloat?' $true
}
$config = $null
if ($runDebloat) {
    $company = Read-YesNo 'Is this a company-managed machine?' $false
    $configName = 'debloat.json'
    if ($company) { $configName = 'debloat-company.json' }
    $config = Join-Path $PSScriptRoot "windows\$configName"
    if (-not (Test-Path -LiteralPath $config)) { throw "missing $config" }
}
$agentService = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
$agentBusy = $agentService -and ($agentService.StartType -ne 'Disabled' -or $agentService.Status -eq 'Running')

if ($runDebloat -or $agentBusy) {
    $work = Join-Path $env:TEMP ('bootstrap-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $elevated = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $PSScriptRoot 'windows\elevated.ps1') + '"'))
        if ($runDebloat) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $zip = Join-Path $work 'Win11Debloat.zip'
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/Raphire/Win11Debloat/releases/download/$DebloatTag/Win11Debloat.zip" -OutFile $zip
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash
            if ($actual -ne $DebloatSha256) { throw "Win11Debloat.zip SHA256 mismatch: expected $DebloatSha256, got $actual" }
            Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'x')
            $script = Get-ChildItem -Path (Join-Path $work 'x') -Recurse -Filter Win11Debloat.ps1 |
                Sort-Object { $_.FullName.Length } | Select-Object -First 1
            if (-not $script) { throw 'Win11Debloat.ps1 not found in the archive' }
            $elevated += @('-Debloat', ('"' + $script.FullName + '"'), '-Config', ('"' + $config + '"'))
        }
        Write-Output 'Starting the elevated step (a UAC prompt follows).'
        $proc = Start-Process -FilePath powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList $elevated
        if ($proc.ExitCode -ne 0) { throw "elevated step failed with exit code $($proc.ExitCode)" }
        if ($runDebloat) {
            New-Item -ItemType Directory -Force -Path $markerDir | Out-Null
            Set-Content -Encoding ASCII -LiteralPath $marker -Value (Get-Date -Format 'yyyy-MM-dd')
        }
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 4. Private repo URL
$url = (Read-Host 'Private dotfiles repo URL (ssh://user@host[:port]/path or user@host:path)').Trim()
if ($url -eq '') { throw 'no URL given' }
$sshHost = $null
$sshPort = 22
if ($url -match '^ssh://(?:[^@/]+@)?(?<h>\[[^\]]+\]|[^:/]+)(?::(?<p>\d+))?/') {
    $sshHost = $Matches.h.Trim('[', ']')
    if ($Matches.p) { $sshPort = [int]$Matches.p }
}
elseif ($url -match '^[^@/:\s]+@(?<h>[^:/@\s]+):(?!//)') {
    $sshHost = $Matches.h
}
else {
    Write-Output 'Not an ssh URL: skipping the Bitwarden agent and host key steps.'
}

if ($sshHost) {
    # 5. Bitwarden SSH agent
    $sshAdd = Join-Path $WinSsh 'ssh-add.exe'
    Invoke-NativeQuiet $sshAdd @('-l') | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Output 'Open Bitwarden, log in, unlock the vault, and enable the SSH agent (Settings, SSH agent).'
        while ($true) {
            $answer = (Read-Host 'Press Enter to check for the agent, q to quit').Trim()
            if ($answer -eq 'q') { exit 1 }
            Invoke-NativeQuiet $sshAdd @('-l') | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            Write-Output 'No key listed yet.'
        }
    }

    # 6. Host key
    $known = Join-Path $HOME '.ssh\known_hosts'
    $hostSpec = $sshHost
    if ($sshPort -ne 22) { $hostSpec = "[$sshHost]:$sshPort" }
    $found = $false
    if (Test-Path -LiteralPath $known) {
        Invoke-NativeQuiet (Join-Path $WinSsh 'ssh-keygen.exe') @('-F', $hostSpec, '-f', $known) | Out-Null
        $found = ($LASTEXITCODE -eq 0)
    }
    if (-not $found) {
        $scan = Join-Path $env:TEMP ('hostkey-' + [guid]::NewGuid() + '.txt')
        try {
            $keys = @(Invoke-NativeQuiet (Join-Path $WinSsh 'ssh-keyscan.exe') @('-p', "$sshPort", $sshHost))
            if ($LASTEXITCODE -ne 0 -or $keys.Count -eq 0) { throw "ssh-keyscan returned no host key for $sshHost" }
            Set-Content -Encoding ASCII -LiteralPath $scan -Value $keys
            Invoke-Native (Join-Path $WinSsh 'ssh-keygen.exe') @('-lf', $scan)
            if (-not (Read-YesNo 'Do these fingerprints match the ones your forge publishes?' $false)) { exit 1 }
            New-Item -ItemType Directory -Force -Path (Split-Path $known) | Out-Null
            Add-Content -Encoding ASCII -LiteralPath $known -Value $keys
        }
        finally {
            Remove-Item -LiteralPath $scan -Force -ErrorAction SilentlyContinue
        }
    }
}

# 7. Clone
$dest = Join-Path $env:LOCALAPPDATA 'dotfiles'
if (Test-Path -LiteralPath $dest) {
    if (-not (Test-Path -LiteralPath (Join-Path $dest '.git'))) {
        Write-Output "$dest exists and is not a git repository."
        exit 1
    }
    Write-Output "$dest is already a git repository: skipping the clone"
}
else {
    Invoke-Native git @('-c', "core.sshCommand=$WinSshCommand", 'clone', $url, $dest)
}
Invoke-Native git @('-C', $dest, 'config', 'core.sshCommand', $WinSshCommand)

# 8. Hand over
$install = Join-Path $dest 'install.ps1'
if (-not (Test-Path -LiteralPath $install)) { throw "missing $install" }
& powershell.exe -ExecutionPolicy Bypass -File $install
exit $LASTEXITCODE
