#requires -Version 5.1
<#
  LeigodAutoPause.ps1
  Watches the Leigod (LeiShen) client process. When the client process truly
  exits (not when the window is merely hidden / minimized to tray), it calls the
  official pause API so no time is consumed. Re-opening the client does not
  resume acceleration automatically.

  It also registers a hidden window that handles WM_QUERYENDSESSION, so a direct
  shutdown / restart / logoff pauses the time immediately before Windows exits.
#>

param([switch]$TestShutdownPause)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$DataDir  = Join-Path $env:APPDATA 'LeigodAutoPause'
$CfgPath  = Join-Path $DataDir 'config.json'
$LogPath  = Join-Path $DataDir 'autopause.log'
$LockPath = Join-Path $DataDir 'instance.lock'

if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

function Write-Log([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 1MB)) {
            Move-Item -Path $LogPath -Destination ($LogPath + '.old') -Force
        }
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    } catch { }
}

# PowerShell 5.1 decodes JSON responses as Latin-1 when the server omits a charset,
# which turns Chinese messages into mojibake. Reverse it for readable logs.
function ConvertFrom-Mojibake([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }
    try {
        return [Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding(28591).GetBytes($s))
    } catch { return $s }
}

if (-not (Test-Path $CfgPath)) {
    Write-Log 'config.json not found; exiting. Run setup.ps1 first.'
    exit 1
}

$cfg = Get-Content -Path $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $cfg.phone -or -not $cfg.passwordMd5) {
    Write-Log 'config.json is missing phone/passwordMd5; exiting.'
    exit 1
}

$PollSeconds = if ($null -ne $cfg.pollSeconds) { [int]$cfg.pollSeconds } else { 2 }

# ---------------------------------------------------------------------------
# Shutdown guard (C#): a hidden top-level window that catches WM_QUERYENDSESSION
# and pauses the account synchronously before Windows powers off.
# ---------------------------------------------------------------------------
if (-not ('LeigodGuardForm' -as [type])) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Net.Http
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public static class LeigodShutdownGuard
{
    private static string _phone;
    private static string _md5;
    private static string _logPath;
    private static bool _done;
    private static readonly object _sync = new object();

    public static void Init(string phone, string md5, string logPath)
    {
        _phone = phone;
        _md5 = md5;
        _logPath = logPath;
        try { ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072; } catch { }
    }

    public static void StartGuard()
    {
        var t = new Thread(GuardLoop);
        t.IsBackground = true;
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
    }

    private static void GuardLoop()
    {
        try
        {
            var f = new LeigodGuardForm();
            Application.Run(f);
        }
        catch (Exception ex) { Log("form error: " + ex.Message); }
    }

    public static void Pause(string reason)
    {
        lock (_sync) { if (_done) return; _done = true; }
        try
        {
            using (var http = new HttpClient())
            {
                http.Timeout = TimeSpan.FromSeconds(3);
                string token = Login(http);
                if (token == null) return;
                var body = "{\"account_token\":\"" + token + "\",\"lang\":\"en\",\"os_type\":5}";
                var resp = http.PostAsync("https://webapi.leigod.com/api/user/pause",
                    new StringContent(body, Encoding.UTF8, "application/json")).Result;
                string text = resp.Content.ReadAsStringAsync().Result;
                Log(reason + " -> pause http=" + (int)resp.StatusCode + " body=" + text);
            }
        }
        catch (Exception ex) { Log(reason + " -> pause error: " + ex.Message); }
    }

    private static string Login(HttpClient http)
    {
        var body = "{\"username\":\"" + _phone + "\",\"password\":\"" + _md5 +
                   "\",\"user_type\":\"0\",\"src_channel\":\"guanwang\"," +
                   "\"code\":\"8fAAIgr3HHmcX7JY\",\"country_code\":86,\"lang\":\"en\",\"os_type\":5}";
        var resp = http.PostAsync("https://webapi.leigod.com/wap/login/bind",
            new StringContent(body, Encoding.UTF8, "application/json")).Result;
        var text = resp.Content.ReadAsStringAsync().Result;
        int i = text.IndexOf("\"account_token\"", StringComparison.Ordinal);
        if (i < 0) { Log("login failed: " + text); return null; }
        int colon = text.IndexOf(':', i);
        int q1 = text.IndexOf('"', colon + 1);
        int q2 = text.IndexOf('"', q1 + 1);
        if (q1 < 0 || q2 < 0) { Log("login parse failed"); return null; }
        return text.Substring(q1 + 1, q2 - q1 - 1);
    }

    private static void Log(string msg)
    {
        try
        {
            File.AppendAllText(_logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " [shutdown-guard] " + msg + "\r\n");
        }
        catch { }
    }
}

public class LeigodGuardForm : Form
{
    public LeigodGuardForm()
    {
        ShowInTaskbar = false;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Location = new System.Drawing.Point(-3000, -3000);
        Size = new System.Drawing.Size(1, 1);
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0011) // WM_QUERYENDSESSION
        {
            LeigodShutdownGuard.Pause("query-end-session");
            m.Result = (IntPtr)1; // allow shutdown
            return;
        }
        base.WndProc(ref m);
    }
}
'@ -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing', 'System.Net.Http'
}

[LeigodShutdownGuard]::Init([string]$cfg.phone, [string]$cfg.passwordMd5, $LogPath)

if ($TestShutdownPause) {
    Write-Log 'test: invoking shutdown pause path'
    [LeigodShutdownGuard]::Pause('manual-test')
    Start-Sleep -Seconds 2
    exit 0
}

# Single instance guard: keep one watcher per user session.
try {
    $me = [System.Diagnostics.Process]::GetCurrentProcess().Id
    if (Test-Path $LockPath) {
        $oldPid = Get-Content $LockPath -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($oldPid) {
            $old = Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue
            if ($old -and $old.ProcessName -eq 'powershell') { exit 0 }
        }
    }
    Set-Content -Path $LockPath -Value $me -Encoding ASCII
} catch { }

[LeigodShutdownGuard]::StartGuard()

$script:Token = $null

function Invoke-LeigodLogin {
    $body = @{
        username     = [string]$cfg.phone
        password     = [string]$cfg.passwordMd5
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
        $script:Token = [string]$resp.data.login_info.account_token
        Write-Log 'login OK'
        return $true
    }
    Write-Log ("login failed: code={0} msg={1}" -f $resp.code, (ConvertFrom-Mojibake ([string]$resp.msg)))
    return $false
}

function Invoke-LeigodPause {
    if (-not $script:Token) { if (-not (Invoke-LeigodLogin)) { return $false } }

    $body = @{
        account_token = $script:Token
        lang          = 'en'
        os_type       = 5
    } | ConvertTo-Json -Compress

    try {
        $resp = Invoke-RestMethod -Uri 'https://webapi.leigod.com/api/user/pause' -Method Post `
            -ContentType 'application/json' -Body $body -TimeoutSec 20
    } catch {
        Write-Log ("pause request error: {0}" -f $_.Exception.Message)
        return $false
    }

    $msgText = ConvertFrom-Mojibake ([string]$resp.msg)
    if ($resp.code -eq 0 -or $resp.code -eq 400803 -or $msgText -match '暂停|pause') {
        Write-Log ("pause OK: code={0} msg={1}" -f $resp.code, $msgText)
        return $true
    }

    # 400007: login state expired -> re-login once and retry.
    if ($resp.code -eq 400007) {
        Write-Log 'token expired, re-login'
        $script:Token = $null
        if (Invoke-LeigodLogin) { return Invoke-LeigodPause }
    }

    Write-Log ("pause failed: code={0} msg={1}" -f $resp.code, $msgText)
    return $false
}

function Get-LeigodUiProcess {
    $procs = @(Get-Process -Name 'leigod' -ErrorAction SilentlyContinue)
    return $procs | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
}

Write-Log ("watcher started (poll={0}s, pause on process exit, shutdown guard on)" -f $PollSeconds)

$hasSeenClient    = $false
$trackedPid       = 0
$pausedForThisRun = $false
$hiddenLogged     = $false

while ($true) {
    try {
        $ui = Get-LeigodUiProcess

        if ($ui) {
            if (-not $hasSeenClient) { Write-Log ("client UI process detected (PID={0})" -f $ui.Id) }
            $hasSeenClient    = $true
            $trackedPid       = $ui.Id
            $pausedForThisRun = $false
            $hiddenLogged     = $false
        }
        elseif ($hasSeenClient -and $trackedPid -gt 0) {
            $stillRunning = Get-Process -Id $trackedPid -ErrorAction SilentlyContinue
            if (-not $stillRunning) {
                if (-not $pausedForThisRun) {
                    $pausedForThisRun = $true
                    Write-Log 'client process exited; pausing now'
                    if (Invoke-LeigodPause) { Write-Log 'time paused automatically' }
                }
            }
            elseif (-not $hiddenLogged) {
                Write-Log 'client window hidden; process still running (no pause)'
                $hiddenLogged = $true
            }
        }
    } catch {
        Write-Log ("watcher error: {0}" -f $_.Exception.Message)
    }

    Start-Sleep -Seconds $PollSeconds
}
