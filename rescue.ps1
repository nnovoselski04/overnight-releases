# Overnight rescue for Windows: for an Overnight window that stays black, dark or empty.
#   irm https://raw.githubusercontent.com/nnovoselski04/overnight-releases/main/rescue.ps1 | iex
# Closes Overnight (only Overnight's own processes) and starts it once with software graphics (--software-graphics:
# drawn by the processor, slower, but it always shows). That start only: to keep it, pick Software in Overnight's
# Settings > System > Graphics once the window shows (Auto, the default, already steps down by itself when it can).
# Projects, settings and the Skool login are not touched. Plain ASCII: Windows PowerShell 5.1 runs it through irm | iex.
# OVERNIGHT_SETUP_DRY=1: test mode, nothing is closed or started.

& {
$ErrorActionPreference = 'Stop'
$DryRun = [bool]$env:OVERNIGHT_SETUP_DRY
function Ok($t) { Write-Host "    [ok] $t" -ForegroundColor Green }
function Note($t) { Write-Host "    $t" -ForegroundColor DarkGray }
function Warn($t) { Write-Host "    [!] $t" -ForegroundColor Yellow }

try {
  Write-Host 'Overnight rescue' -ForegroundColor White
  Note 'Your projects, settings and Skool login stay as they are.'
  $dir = $null
  $e = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'Overnight' -and $_.InstallLocation } | Select-Object -First 1
  if ($e) { $dir = [string]$e.InstallLocation.TrimEnd('\') } else { $dir = Join-Path $env:LOCALAPPDATA 'Programs\overnight' }
  $exe = Join-Path $dir 'Overnight.exe'
  if (-not (Test-Path -LiteralPath $exe)) {
    Write-Host ''; Write-Host 'Overnight is not installed on this computer. Install it with:' -ForegroundColor Red
    Write-Host '  irm https://raw.githubusercontent.com/nnovoselski04/overnight-releases/main/install.ps1 | iex'
    throw 'OVN_STOP'
  }

  Write-Host ''; Write-Host '==> Closing Overnight' -ForegroundColor White
  $own = { @(Get-Process -Name 'Overnight' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -ieq $exe }) }
  $procs = & $own
  if (-not $procs.Count) { Ok 'it was not running' }
  elseif ($DryRun) { Note "(test mode) would close $($procs.Count) Overnight process(es)" }
  else {
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 30 -and (& $own).Count; $i++) { Start-Sleep -Milliseconds 500 }
    if ((& $own).Count) { Warn 'it is still closing; if Overnight does not open below, restart the computer and run this again' } else { Ok 'closed' }
  }

  Write-Host ''; Write-Host '==> Starting Overnight with software graphics' -ForegroundColor White
  if ($DryRun) { Note "(test mode) would start $exe --software-graphics" }
  else { Start-Process -FilePath $exe -ArgumentList '--software-graphics'; Ok 'started (slower drawing, but it always shows)' }
  Write-Host ''
  Write-Host 'This rescue start is not saved. To keep software graphics for the next starts: once the window shows,' -ForegroundColor White
  Write-Host 'Settings > System > Graphics > Software.' -ForegroundColor White
}
catch { if ("$_" -ne 'OVN_STOP') { Write-Host ''; Write-Host "Rescue stopped: $_" -ForegroundColor Red } }
}
