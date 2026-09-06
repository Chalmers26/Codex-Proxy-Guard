[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BaseDir = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $BaseDir 'config.json'
$StatePath = Join-Path $BaseDir 'state.json'

function Test-TcpPort([string]$HostName, [int]$Port, [int]$TimeoutMs = 900) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($connect)
        return $true
    } catch { return $false }
    finally { $client.Close() }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "No installed configuration at $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Host 'Codex Proxy Guard status'
Write-Host ''
Write-Host 'Configured recovery program:'
$program = [Environment]::ExpandEnvironmentVariables([string]$config.ProxyProgramPath)
Write-Host "  path=$program"
Write-Host "  exists=$(Test-Path -LiteralPath $program -PathType Leaf)"

Write-Host ''
Write-Host 'Configured proxy listeners:'
foreach ($path in @($config.ProxyConfigPaths)) {
    $expanded = [Environment]::ExpandEnvironmentVariables([string]$path)
    Write-Host "  config=$expanded exists=$(Test-Path -LiteralPath $expanded -PathType Leaf)"
}

Write-Host ''
Write-Host 'Windows system proxy:'
$settings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Write-Host "  enabled=$($settings.ProxyEnable) server=$($settings.ProxyServer)"

Write-Host ''
Write-Host 'Current user proxy environment:'
foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')) {
    Write-Host "  $name=$([Environment]::GetEnvironmentVariable($name, 'User'))"
}

Write-Host ''
Write-Host 'Known local listener ports:'
foreach ($port in @($config.PreferredPorts)) {
    if (Test-TcpPort '127.0.0.1' ([int]$port)) { Write-Host "  127.0.0.1:$port reachable=True" }
}

Write-Host ''
Write-Host 'Recovery state:'
if (Test-Path -LiteralPath $StatePath) {
    $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "  activeProxy=$($state.ActiveProxy) downChecks=$($state.ProxyDownCount) outageConfirmed=$($state.ProxyOutageConfirmed)"
} else { Write-Host '  no state file yet' }
