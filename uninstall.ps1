#requires -Version 5.1
<#
  uninstall.ps1 - stop the watcher, remove the scheduled task and config.
#>

$ErrorActionPreference = 'SilentlyContinue'
$DataDir  = Join-Path $env:APPDATA 'LeigodAutoPause'
$TaskName = 'LeigodAutoPause'
$LockPath = Join-Path $DataDir 'instance.lock'

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "Scheduled task '$TaskName' removed."

if (Test-Path $LockPath) {
    $watchPid = Get-Content $LockPath | Select-Object -First 1
    if ($watchPid) {
        $p = Get-Process -Id ([int]$watchPid) -ErrorAction SilentlyContinue
        if ($p -and ($p.ProcessName -eq 'LeigodAutoPause' -or $p.ProcessName -eq 'powershell')) { Stop-Process -Id $p.Id -Force }
    }
    Remove-Item $LockPath -Force
    Write-Host 'Watcher process stopped.'
}

Remove-Item -Path (Join-Path $DataDir 'config.json') -Force
Write-Host 'Config (phone + password hash) deleted.'
Write-Host "To fully remove, delete the folder: $PSScriptRoot"
