[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:APPDATA 'CodexProxyGuard'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValueName = 'CodexProxyGuard'
$backupPath = Join-Path $InstallDir 'environment-backup.json'

function Restore-UserEnvironment {
    if (-not (Test-Path -LiteralPath $backupPath)) { return }
    $backup = Get-Content -LiteralPath $backupPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($property in $backup.Values.PSObject.Properties) {
        [Environment]::SetEnvironmentVariable($property.Name, $property.Value, 'User')
        [Environment]::SetEnvironmentVariable($property.Name, $property.Value, 'Process')
    }
}

$runValue = (Get-ItemProperty -Path $RunKey -Name $RunValueName -ErrorAction SilentlyContinue).$RunValueName
if ($runValue -and $runValue -like "*$InstallDir\\CodexProxyGuard.ps1*") {
    if ($PSCmdlet.ShouldProcess("$RunKey\\$RunValueName", 'Remove Codex Proxy Guard startup entry')) {
        Remove-ItemProperty -Path $RunKey -Name $RunValueName -Force
    }
}

if ($PSCmdlet.ShouldProcess('user proxy environment variables', 'Restore values saved by Codex Proxy Guard')) { Restore-UserEnvironment }

$guard = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like "*$InstallDir\\CodexProxyGuard.ps1*"
}
foreach ($process in @($guard)) {
    if ($PSCmdlet.ShouldProcess("PID $($process.ProcessId)", 'Stop Codex Proxy Guard')) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
}

if (Test-Path -LiteralPath $InstallDir) {
    $resolved = [IO.Path]::GetFullPath($InstallDir)
    $expected = [IO.Path]::GetFullPath((Join-Path $env:APPDATA 'CodexProxyGuard'))
    if ($resolved -ne $expected) { throw 'Refusing to remove an unexpected directory.' }
    if ($PSCmdlet.ShouldProcess($InstallDir, 'Remove Codex Proxy Guard installation and logs')) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    }
}
Write-Host 'Codex Proxy Guard was removed. Windows system proxy settings were not changed.'
