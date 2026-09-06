[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$required = @('CodexProxyGuard.ps1', 'install.ps1', 'uninstall.ps1', 'status.ps1', 'config.example.json', 'README.md', 'LICENSE', 'CHANGELOG.md')

foreach ($file in $required) {
    $path = Join-Path $Root $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing required file: $file" }
}

Get-Content -LiteralPath (Join-Path $Root 'config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
foreach ($script in @('CodexProxyGuard.ps1', 'install.ps1', 'uninstall.ps1', 'status.ps1')) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $Root $script), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "PowerShell syntax error in ${script}: $($errors[0].Message)" }
}

$forbidden = @('D:\\v2rayN', 'CodexProxyGuard.Chalmers', 'Chalmers\\AppData')
$publicText = Get-ChildItem -LiteralPath $Root -File -Recurse | Where-Object { $_.FullName -notmatch '\\(tests|\.git)\\' } | Get-Content -Raw
foreach ($value in $forbidden) {
    if ($publicText -match [regex]::Escape($value)) { throw "Found machine-specific or runtime value: $value" }
}
Write-Host 'Project verification passed.'
