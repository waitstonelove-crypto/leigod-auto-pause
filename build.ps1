#requires -Version 5.1
<#
  build.ps1 - compile LeigodAutoPause.cs into LeigodAutoPause.exe
  using the C# compiler that ships with the .NET Framework
  (no .NET SDK required).
#>

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$fw   = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$csc  = Join-Path $fw 'csc.exe'

if (-not (Test-Path $csc)) { throw "C# compiler not found: $csc" }

$src = Join-Path $root 'LeigodAutoPause.cs'
$out = Join-Path $root 'LeigodAutoPause.exe'
if (-not (Test-Path $src)) { throw "source not found: $src" }

$refs = @(
    'System.dll',
    'System.Core.dll',
    'System.Windows.Forms.dll',
    'System.Drawing.dll',
    'System.Net.Http.dll',
    'System.Web.Extensions.dll'
)

$args = @('/nologo', '/target:winexe', '/optimize+', ('/out:' + $out), $src)
foreach ($r in $refs) { $args += ('/reference:' + (Join-Path $fw $r)) }

& $csc @args
if ($LASTEXITCODE -ne 0) { throw "build failed with exit code $LASTEXITCODE" }

Write-Host "built: $out" -ForegroundColor Green
