[CmdletBinding()]
param(
    [string]$ProxyProgramPath = '',
    [string]$ProxyConfigPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SourceDir = Split-Path -Parent $PSCommandPath
$InstallDir = Join-Path $env:APPDATA 'CodexProxyGuard'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValueName = 'CodexProxyGuard'

function Find-RunningProxyProgram {
    foreach ($name in @('v2rayN', 'clash', 'mihomo', 'sing-box', 'nekoray', 'hiddify')) {
        $process = Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($process -and $process.Path -and (Test-Path -LiteralPath $process.Path -PathType Leaf)) { return $process.Path }
    }
    return ''
}

function Find-AdjacentConfig([string]$Program) {
    if ([string]::IsNullOrWhiteSpace($Program)) { return '' }
    $directory = Split-Path -Parent $Program
    foreach ($candidate in @(
        (Join-Path $directory 'binConfigs\config.json'),
        (Join-Path $directory 'config.json'),
        (Join-Path (Split-Path -Parent $directory) 'binConfigs\config.json')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return ''
}

if (-not (Test-Path -LiteralPath (Join-Path $SourceDir 'CodexProxyGuard.ps1'))) {
    throw 'Run install.ps1 from the extracted project directory.'
}

if ([string]::IsNullOrWhiteSpace($ProxyProgramPath)) { $ProxyProgramPath = Find-RunningProxyProgram }
if (-not [string]::IsNullOrWhiteSpace($ProxyProgramPath)) {
    $ProxyProgramPath = [Environment]::ExpandEnvironmentVariables($ProxyProgramPath)
    if (-not (Test-Path -LiteralPath $ProxyProgramPath -PathType Leaf)) { throw "Proxy program not found: $ProxyProgramPath" }
    $ProxyProgramPath = [IO.Path]::GetFullPath($ProxyProgramPath)
}
if ([string]::IsNullOrWhiteSpace($ProxyConfigPath)) { $ProxyConfigPath = Find-AdjacentConfig $ProxyProgramPath }
if (-not [string]::IsNullOrWhiteSpace($ProxyConfigPath)) {
    $ProxyConfigPath = [Environment]::ExpandEnvironmentVariables($ProxyConfigPath)
    if (-not (Test-Path -LiteralPath $ProxyConfigPath -PathType Leaf)) { throw "Proxy configuration not found: $ProxyConfigPath" }
    $ProxyConfigPath = [IO.Path]::GetFullPath($ProxyConfigPath)
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
foreach ($file in @('CodexProxyGuard.ps1', 'status.ps1', 'uninstall.ps1', 'config.example.json')) {
    Copy-Item -LiteralPath (Join-Path $SourceDir $file) -Destination (Join-Path $InstallDir $file) -Force
}

$config = Get-Content -LiteralPath (Join-Path $SourceDir 'config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$config.ProxyProgramPath = $ProxyProgramPath
$config.ProxyConfigPaths = if ([string]::IsNullOrWhiteSpace($ProxyConfigPath)) { @() } else { @($ProxyConfigPath) }
$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $InstallDir 'config.json') -Encoding UTF8

$powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$guard = Join-Path $InstallDir 'CodexProxyGuard.ps1'
$arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $guard
New-Item -Path $RunKey -Force | Out-Null
Set-ItemProperty -Path $RunKey -Name $RunValueName -Value ('"{0}" {1}' -f $powershell, $arguments)

Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden
Write-Host "Installed Codex Proxy Guard to $InstallDir"
if ($ProxyProgramPath) { Write-Host "Detected proxy program: $ProxyProgramPath" }
else { Write-Host 'No running proxy program was detected. Listener and Windows system-proxy detection remain enabled.' }
Write-Host 'The guard does not change the Windows system proxy setting.'
