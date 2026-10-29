#requires -Version 5.1
<#
  setup.ps1 - one-time setup for LeigodAutoPause.

  Prompts for your Leigod phone number and password. The password is converted
  to an MD5 hash (what the official API expects) and stored locally in
  %APPDATA%\LeigodAutoPause\config.json. The plain password is never written.

  It then registers a Scheduled Task that starts the watcher at every logon,
  and starts it immediately.
#>

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$DataDir = Join-Path $env:APPDATA 'LeigodAutoPause'
$CfgPath = Join-Path $DataDir 'config.json'
$TaskName = 'LeigodAutoPause'
$Watcher = Join-Path $PSScriptRoot 'LeigodAutoPause.exe'

if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

if (-not (Test-Path $Watcher)) {
    $build = Join-Path $PSScriptRoot 'build.ps1'
    if (Test-Path $build) {
        Write-Host 'Watcher executable not found, building it...' -ForegroundColor Cyan
        & $build
    }
    if (-not (Test-Path $Watcher)) { throw "Watcher executable not found: $Watcher" }
}

Write-Host ''
Write-Host '=== Leigod Auto Pause - setup ===' -ForegroundColor Cyan
Write-Host 'Your credentials stay on this PC. Only an MD5 password hash is stored.' -ForegroundColor DarkGray
Write-Host ''

$phone = Read-Host 'Leigod phone number'
$phone = ($phone -replace '\s', '')
if ($phone -notmatch '^\d{6,15}$') { throw 'Phone number should be digits only.' }

$secure = Read-Host 'Leigod password' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
if ([string]::IsNullOrEmpty($plain)) { throw 'Password cannot be empty.' }

$md5  = [System.Security.Cryptography.MD5]::Create()
$hash = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($plain))
$passwordMd5 = -join ($hash | ForEach-Object { $_.ToString('x2') })
$md5.Dispose()
$plain = $null

$cfg = [ordered]@{
    phone       = $phone
    passwordMd5 = $passwordMd5
    pollSeconds = 1
} | ConvertTo-Json
Set-Content -Path $CfgPath -Value $cfg -Encoding UTF8
Write-Host "Config saved to $CfgPath" -ForegroundColor Green

# Verify the credentials can log in (does not start/pause acceleration).
Write-Host ''
Write-Host 'Checking account login...' -ForegroundColor Cyan
try {
    $body = @{
        username     = $phone
        password     = $passwordMd5
        user_type    = '0'
        src_channel  = 'guanwang'
        code         = '8fAAIgr3HHmcX7JY'
        country_code = 86
        lang         = 'en'
        os_type      = 5
    } | ConvertTo-Json -Compress
    $resp = Invoke-RestMethod -Uri 'https://webapi.leigod.com/wap/login/bind' -Method Post `
        -ContentType 'application/json' -Body $body -TimeoutSec 20
    if ($resp.code -eq 0 -and $resp.data.login_info.account_token) {
        Write-Host 'Login OK - credentials are correct.' -ForegroundColor Green
    } else {
        Write-Host ("Login check failed: code={0} msg={1}" -f $resp.code, $resp.msg) -ForegroundColor Yellow
        Write-Host 'The watcher will still run, but pause may fail. Re-run setup if the password is wrong.' -ForegroundColor Yellow
    }
} catch {
    Write-Host ("Login check error: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
}

# Register (or update) the logon task.
Write-Host ''
Write-Host 'Registering start-at-logon task...' -ForegroundColor Cyan
$action = New-ScheduledTaskAction -Execute $Watcher -WorkingDirectory $PSScriptRoot

$logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$logon.Delay = 'PT5S'
# Self-heal: while the watcher is alive, MultipleInstances=IgnoreNew makes these
# periodic triggers no-ops; if it dies, the next tick restarts it.
$repeat = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($logon, $repeat) `
    -Settings $settings -Description 'Pause Leigod time when the client process exits or the PC shuts down.' -Force | Out-Null
Write-Host "Task '$TaskName' registered." -ForegroundColor Green

# Start now.
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3
$running = Get-Process -Name 'LeigodAutoPause' -ErrorAction SilentlyContinue
Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
if ($running) {
    Write-Host ("The watcher is running (PID {0})." -f $running.Id)
} else {
    Write-Host 'The watcher is not running; check the log below.' -ForegroundColor Yellow
}
Write-Host 'Fully quitting the Leigod client pauses the time within ~1 second.'
Write-Host "Log: $DataDir\autopause.log"
Write-Host "Uninstall: powershell -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'uninstall.ps1')`""
