# collect-results.ps1 — gather the tester report + logs into results/
# NEVER copies tester.ini or login.ini (they contain the demo password).
#
# Looks in the portable data folder ($MT5_DIR) first, then in the %APPDATA%
# terminal folders as a fallback (in case /portable did not apply on the run).
# Best-effort: missing files are reported, not fatal — the step must not fail
# just because a report was never produced.

param(
    [string]$Mt5Dir = $env:MT5_DIR,
    [string]$OutDir = 'results'
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutDir 'logs') | Out-Null

$reportDirs = @()
if (-not [string]::IsNullOrWhiteSpace($Mt5Dir)) { $reportDirs += $Mt5Dir }
$appDataTerminals = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
if (Test-Path $appDataTerminals) {
    $reportDirs += Get-ChildItem $appDataTerminals -Directory | ForEach-Object { $_.FullName }
}

$foundReport = $false
foreach ($dir in $reportDirs) {
    $htm = Join-Path $dir 'AutoTrade-Backtest.htm'
    $png = Join-Path $dir 'AutoTrade-Backtest.png'
    if (Test-Path $htm) { Copy-Item $htm (Join-Path $OutDir 'AutoTrade-Backtest.htm'); $foundReport = $true }
    if (Test-Path $png) { Copy-Item $png (Join-Path $OutDir 'AutoTrade-Backtest.png') }
    $logsDir = Join-Path $dir 'Logs'
    if (Test-Path $logsDir) { Copy-Item (Join-Path $logsDir '*.log') (Join-Path $OutDir 'logs') -ErrorAction SilentlyContinue }
}

if (-not [string]::IsNullOrWhiteSpace($Mt5Dir)) {
    $compileLog = Join-Path $Mt5Dir 'MQL5\Experts\AutoTrade-compile.log'
    if (Test-Path $compileLog) { Copy-Item $compileLog (Join-Path $OutDir 'AutoTrade-compile.log') }
}
Copy-Item 'ea\AutoTrade.set' (Join-Path $OutDir 'AutoTrade.set') -ErrorAction SilentlyContinue
Copy-Item 'tester\tester.ini.template' (Join-Path $OutDir 'tester.ini.template') -ErrorAction SilentlyContinue

# Best-effort metric parse from the .htm report (UTF-16).
$summary = @()
$summary += '# AutoTrade backtest — result summary'
$summary += ''
if ($foundReport) {
    $summary += 'Report found: AutoTrade-Backtest.htm'
    try {
        $html = Get-Content -Raw -Encoding Unicode -Path (Join-Path $OutDir 'AutoTrade-Backtest.htm')
        foreach ($label in @('Total Trades', 'Total Net Profit', 'Profit Factor', 'Expected Payoff', 'Maximal Drawdown')) {
            $m = [regex]::Match($html, [regex]::Escape($label) + '</td>\s*<td[^>]*>([^<]+)</td>')
            if ($m.Success) { $summary += "- ${label}: $($m.Groups[1].Value.Trim())" }
        }
    } catch {
        $summary += 'Metric parse failed — open AutoTrade-Backtest.htm directly.'
    }
} else {
    $summary += 'NO REPORT FOUND — the tester did not produce AutoTrade-Backtest.htm.'
    $summary += 'Check logs/ for the journal: login failure, no history, or a timeout are the usual causes.'
}
$summary += ''
$summary += 'Files in this artifact: AutoTrade-Backtest.htm (+ .png equity chart), logs/ (terminal journal), AutoTrade-compile.log, AutoTrade.set, tester.ini.template.'
Set-Content -Path (Join-Path $OutDir 'SUMMARY.md') -Value ($summary -join "`n") -Encoding UTF8
Write-Host ($summary -join "`n")
