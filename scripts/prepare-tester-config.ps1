# prepare-tester-config.ps1 — generate tester.ini + login.ini from templates
# using GitHub Secrets (never committed, never printed).
#
# Required env vars (set by the workflow from secrets / dispatch inputs):
#   HFM_MT5_LOGIN, HFM_MT5_PASSWORD, HFM_MT5_SERVER
#   BT_FROM_DATE, BT_TO_DATE, BT_MODEL, BT_DEPOSIT
#   MT5_DIR — MT5 install folder (the /portable data folder).
#
# Safety: String.Replace is literal (no regex), so passwords containing $ or
# regex characters are safe. The generated files are never printed, and the
# collect step never uploads them.

param(
    [string]$TemplatePath = 'tester/tester.ini.template',
    [string]$LoginTemplatePath = 'tester/login.ini.template',
    [string]$OutputDir = $env:MT5_DIR
)
$ErrorActionPreference = 'Stop'

function Get-RequiredEnv([string]$Name) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { throw "Required secret/env var $Name is empty or missing." }
    return $v
}

$login    = Get-RequiredEnv 'HFM_MT5_LOGIN'
$password = Get-RequiredEnv 'HFM_MT5_PASSWORD'
$server   = Get-RequiredEnv 'HFM_MT5_SERVER'
$fromDate = Get-RequiredEnv 'BT_FROM_DATE'
$toDate   = Get-RequiredEnv 'BT_TO_DATE'
$model    = Get-RequiredEnv 'BT_MODEL'
$deposit  = Get-RequiredEnv 'BT_DEPOSIT'

if ([string]::IsNullOrWhiteSpace($OutputDir)) { throw 'MT5_DIR is not set.' }

$template = Get-Content -Raw -Path $TemplatePath
$filled = $template.Replace('__HFM_LOGIN__', $login).
    Replace('__HFM_PASSWORD__', $password).
    Replace('__HFM_SERVER__', $server).
    Replace('__FROM_DATE__', $fromDate).
    Replace('__TO_DATE__', $toDate).
    Replace('__MODEL__', $model).
    Replace('__DEPOSIT__', $deposit)

if ($filled -match '__[A-Z_]+__') { throw 'Unresolved placeholder remains in tester.ini — check template and inputs.' }
Set-Content -Path (Join-Path $OutputDir 'tester.ini') -Value $filled -Encoding UTF8

$loginTemplate = Get-Content -Raw -Path $LoginTemplatePath
$loginFilled = $loginTemplate.Replace('__HFM_LOGIN__', $login).
    Replace('__HFM_PASSWORD__', $password).
    Replace('__HFM_SERVER__', $server)
if ($loginFilled -match '__[A-Z_]+__') { throw 'Unresolved placeholder remains in login.ini.' }
Set-Content -Path (Join-Path $OutputDir 'login.ini') -Value $loginFilled -Encoding UTF8

Write-Host 'tester.ini and login.ini generated in the MT5 folder (contents not printed).'
