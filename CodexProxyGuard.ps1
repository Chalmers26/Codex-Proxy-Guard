[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BaseDir = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $BaseDir 'config.json'
$StatePath = Join-Path $BaseDir 'state.json'
$EnvironmentBackupPath = Join-Path $BaseDir 'environment-backup.json'
$LogDir = Join-Path $BaseDir 'logs'
$LogPath = Join-Path $LogDir 'guard.log'
$MutexName = 'Global\CodexProxyGuard'

function Read-JsonFile([string]$Path, $Default) {
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw.IndexOf([char]0) -ge 0) { return $Default }
        return ($raw | ConvertFrom-Json)
    } catch { return $Default }
}

function Save-JsonFile([string]$Path, $Value) {
    $directory = Split-Path -Parent $Path
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Get-Config {
    $config = Read-JsonFile $ConfigPath $null
    if ($null -eq $config) { throw "Missing or invalid configuration: $ConfigPath" }
    return $config
}

function Write-Log([string]$Message, [string]$Level = 'INFO') {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Rotate-Log($Config) {
    if (-not (Test-Path -LiteralPath $LogPath)) { return }
    $maximum = [int64]$Config.LogMaxMB * 1MB
    if ((Get-Item -LiteralPath $LogPath).Length -lt $maximum) { return }
    for ($i = [int]$Config.LogKeepFiles; $i -ge 1; $i--) {
        $source = "$LogPath.$i"
        if (-not (Test-Path -LiteralPath $source)) { continue }
        if ($i -eq [int]$Config.LogKeepFiles) { Remove-Item -LiteralPath $source -Force }
        else { Move-Item -LiteralPath $source -Destination "$LogPath.$($i + 1)" -Force }
    }
    Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force
}

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

function New-ProxyCandidate([string]$Address, [int]$Port, [string]$Source, [int]$Score) {
    if ([string]::IsNullOrWhiteSpace($Address) -or $Address -in @('0.0.0.0', '::', '::1')) { $Address = '127.0.0.1' }
    [pscustomobject]@{ Address = $Address; Port = $Port; Source = $Source; Score = $Score }
}

function Get-SystemProxyCandidates {
    try {
        $settings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        if ([int]$settings.ProxyEnable -ne 1 -or [string]::IsNullOrWhiteSpace($settings.ProxyServer)) { return @() }
        foreach ($part in ([string]$settings.ProxyServer -split ';')) {
            $endpoint = ($part.Trim() -replace '^[a-zA-Z]+=', '')
            if ($endpoint -match '^(?<host>[^:]+):(?<port>\d+)$') {
                New-ProxyCandidate $Matches.host ([int]$Matches.port) 'Windows system proxy' 70
            }
        }
    } catch { Write-Log "Could not read Windows system proxy: $($_.Exception.Message)" 'WARN' }
}

function Get-ProxyConfigCandidates($Config) {
    foreach ($rawPath in @($Config.ProxyConfigPaths)) {
        $path = [Environment]::ExpandEnvironmentVariables([string]$rawPath)
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($inbound in @($json.inbounds)) {
                if (-not $inbound.port -or [string]$inbound.protocol -notmatch 'http|socks|mixed') { continue }
                $listen = if ($inbound.listen) { [string]$inbound.listen } else { '127.0.0.1' }
                $score = if ([string]$inbound.protocol -match 'mixed|http') { 100 } else { 90 }
                New-ProxyCandidate $listen ([int]$inbound.port) "proxy config ($([string]$inbound.protocol))" $score
            }
        } catch { Write-Log "Could not parse proxy configuration '$path': $($_.Exception.Message)" 'WARN' }
    }
}

function Get-ListeningProxyCandidates($Config) {
    $names = @($Config.PreferredProxyPrograms)
    $ports = @($Config.PreferredPorts | ForEach-Object { [int]$_ })
    foreach ($connection in (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
        if ($connection.LocalAddress -notin @('127.0.0.1', '::1', '0.0.0.0', '::')) { continue }
        $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        $nameMatch = @($names | Where-Object { $process.ProcessName -like "*$_*" }).Count -gt 0
        $portMatch = $ports -contains [int]$connection.LocalPort
        if (-not $nameMatch -and -not $portMatch) { continue }
        $score = 40 + $(if ($nameMatch) { 20 } else { 0 }) + $(if ($portMatch) { 10 } else { 0 })
        New-ProxyCandidate $connection.LocalAddress ([int]$connection.LocalPort) "listener $($process.ProcessName)" $score
    }
}

function Get-EffectiveProxy($Config) {
    $candidates = @(Get-ProxyConfigCandidates $Config) + @(Get-SystemProxyCandidates) + @(Get-ListeningProxyCandidates $Config)
    $candidates | Where-Object { Test-TcpPort $_.Address $_.Port } |
        Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Port'; Descending = $false } |
        Select-Object -First 1
}

function Save-EnvironmentBackup {
    if (Test-Path -LiteralPath $EnvironmentBackupPath) { return }
    $values = [ordered]@{}
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'NO_PROXY', 'no_proxy')) {
        $values[$name] = [Environment]::GetEnvironmentVariable($name, 'User')
    }
    Save-JsonFile $EnvironmentBackupPath ([pscustomobject]@{ Version = 1; Values = $values })
}

function Set-UserEnvironmentValue([string]$Name, [string]$Value) {
    if ([Environment]::GetEnvironmentVariable($Name, 'User') -ne $Value) {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
        Write-Log "Set user environment variable $Name."
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

function Update-ProxyEnvironment([string]$ProxyUri, [string]$NoProxy) {
    Save-EnvironmentBackup
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) { Set-UserEnvironmentValue $name $ProxyUri }
    foreach ($name in @('NO_PROXY', 'no_proxy')) { Set-UserEnvironmentValue $name $NoProxy }
}

function Get-State {
    $default = [pscustomobject]@{
        ActiveProxy = ''; PendingProxy = ''; PendingCount = 0; LastRestartUtc = '1970-01-01T00:00:00Z'
        ProxyDownCount = 0; ProxyOutageConfirmed = $false; LastProxyProgramRestartUtc = '1970-01-01T00:00:00Z'
    }
    $state = Read-JsonFile $StatePath $default
    foreach ($property in $default.PSObject.Properties) {
        if (-not $state.PSObject.Properties[$property.Name]) { $state | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
    }
    return $state
}

function Restart-ProxyProgram($Config) {
    $path = [Environment]::ExpandEnvironmentVariables([string]$Config.ProxyProgramPath)
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Log 'Proxy recovery was skipped: no proxy program is configured.' 'WARN'
        return $false
    }
    $directory = Split-Path -Parent $path
    $processes = @(Get-Process -Name 'v2rayN', 'xray', 'clash', 'mihomo', 'sing-box' -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path.StartsWith($directory, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
    })
    foreach ($process in $processes) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    Start-Process -FilePath $path -WorkingDirectory $directory -WindowStyle Hidden
    Write-Log "Started configured proxy program."
    return $true
}

function Get-CodexProcesses($Config) {
    $patterns = @($Config.CodexProcessPathPatterns)
    Get-Process -Name 'codex' -ErrorAction SilentlyContinue | Where-Object {
        $path = [string]$_.Path
        @($patterns | Where-Object { $path -like "*$_*" }).Count -gt 0
    }
}

function Restart-Codex($Config, [string]$Reason) {
    Write-Log "Restarting Codex: $Reason"
    foreach ($process in @(Get-CodexProcesses $Config)) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds ([int]$Config.CodexStartupDelaySeconds)
    foreach ($rawGlob in @($Config.CodexExecutableGlobs)) {
        $executable = Get-ChildItem -Path ([Environment]::ExpandEnvironmentVariables([string]$rawGlob)) -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($executable) { Start-Process -FilePath $executable.FullName -WindowStyle Hidden; return }
    }
    try { $app = Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -eq 'Codex' } | Select-Object -First 1 }
    catch { $app = $null; Write-Log "Could not query installed apps: $($_.Exception.Message)" 'WARN' }
    if ($app) { Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($app.AppID)" -WindowStyle Hidden }
    else { Write-Log 'Could not find a Codex launch target.' 'ERROR' }
}

$createdNew = $false
$mutex = [Threading.Mutex]::new($true, $MutexName, [ref]$createdNew)
if (-not $createdNew) { exit 0 }

try {
    $config = Get-Config
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    Write-Log 'Codex Proxy Guard started.'
    while ($true) {
        try {
            Rotate-Log $config
            $state = Get-State
            $proxy = Get-EffectiveProxy $config
            if ($null -eq $proxy) {
                $state.ProxyDownCount = [int]$state.ProxyDownCount + 1
                if ($state.ProxyDownCount -eq 1) { Write-Log 'Proxy outage detected; waiting for confirmation.' 'WARN' }
                if ($state.ProxyDownCount -ge [int]$config.ProxyDownChecksBeforeRecovery) {
                    $state.ProxyOutageConfirmed = $true
                    $lastRestart = [datetime]::Parse([string]$state.LastProxyProgramRestartUtc).ToUniversalTime()
                    if (([datetime]::UtcNow - $lastRestart).TotalSeconds -ge [int]$config.ProxyProgramRestartDebounceSeconds) {
                        if (Restart-ProxyProgram $config) { $state.LastProxyProgramRestartUtc = [datetime]::UtcNow.ToString('o') }
                    }
                }
                Save-JsonFile $StatePath $state
                Start-Sleep -Seconds ([int]$config.CheckIntervalSeconds)
                continue
            }
            $recovered = [bool]$state.ProxyOutageConfirmed
            $state.ProxyDownCount = 0
            $proxyUri = [string]::Format([string]$config.ProxyUriTemplate, $proxy.Address, $proxy.Port)
            if ($state.PendingProxy -eq $proxyUri) { $state.PendingCount = [int]$state.PendingCount + 1 }
            else { $state.PendingProxy = $proxyUri; $state.PendingCount = 1 }
            $stable = [int]$state.PendingCount -ge [int]$config.StableChecksRequired
            if ($stable) { Update-ProxyEnvironment $proxyUri ([string]$config.NoProxy) }
            if ($stable -and ($proxyUri -ne $state.ActiveProxy -or $recovered)) {
                $lastRestart = [datetime]::Parse([string]$state.LastRestartUtc).ToUniversalTime()
                if (([datetime]::UtcNow - $lastRestart).TotalSeconds -ge [int]$config.RestartDebounceSeconds) {
                    Restart-Codex $config "proxy available at $proxyUri from $($proxy.Source)"
                    $state.ActiveProxy = $proxyUri
                    $state.ProxyOutageConfirmed = $false
                    $state.LastRestartUtc = [datetime]::UtcNow.ToString('o')
                }
            }
            Save-JsonFile $StatePath $state
        } catch { Write-Log "Guard loop error: $($_.Exception.Message)" 'ERROR'; Start-Sleep -Seconds 10 }
        Start-Sleep -Seconds ([int]$config.CheckIntervalSeconds)
    }
} finally {
    $mutex.ReleaseMutex() | Out-Null
    $mutex.Dispose()
}
