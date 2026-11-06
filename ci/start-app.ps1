# CI: start Overnight the way a member does and prove it started from its own log.
#   ci/start-app.ps1            the real start: the Skool sign-in window comes first (the gate). Proof: a new
#                               `--- Overnight <version> on win32` line, then a `skool check ...` line
#   ci/start-app.ps1 -Ungated   a start with a scratch profile (OVERNIGHT_PROFILE turns the gate off): the main window
#                               loads, and the app's own first-paint check writes `graphics: the window drew (...)`
param([switch]$Ungated, [int]$Seconds = 120)
$ErrorActionPreference = 'Stop'
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$out = Join-Path $env:GITHUB_WORKSPACE 'ci-out'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$exe = Join-Path $env:LOCALAPPDATA 'Programs\overnight\Overnight.exe'
$tag = if ($Ungated) { 'ungated' } else { 'gated' }
function Own { @(Get-Process -Name 'Overnight' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -ieq $exe }) }
function Close-Own { Own | Stop-Process -Force -ErrorAction SilentlyContinue; for ($i = 0; $i -lt 30 -and (Own).Count; $i++) { Start-Sleep -Milliseconds 500 } }

$was = Own
if ($was.Count) { "Overnight was already running (pids $(($was | ForEach-Object Id) -join ', ')): its installer or an earlier step started it. Closing it for a clean start." ; Close-Own }

if ($Ungated) {
  $prof = Join-Path $env:RUNNER_TEMP 'ov-ungated-profile'
  $env:OVERNIGHT_PROFILE = $prof; $env:OVERNIGHT_WORKSPACE = Join-Path $env:RUNNER_TEMP 'ov-ungated-ws'
  $log = Join-Path $prof 'logs\overnight.log'
  $want = @('^\S+ --- Overnight \S+ on win32', '^\S+ graphics (the window drew|window check|window blank|.*failed)')
} else {
  Remove-Item Env:OVERNIGHT_PROFILE -ErrorAction SilentlyContinue
  $log = Join-Path $env:APPDATA 'Overnight\logs\overnight.log'
  $want = @('^\S+ --- Overnight \S+ on win32', '^\S+ skool check ')
}
$before = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log).Count } else { 0 }
"starting $exe ($tag); log $log has $before line(s) before"
$p = Start-Process -FilePath $exe -PassThru
$found = @{}; $new = @()
for ($s = 0; $s -lt $Seconds -and $found.Count -lt $want.Count; $s += 2) {
  Start-Sleep -Seconds 2
  if (-not (Test-Path -LiteralPath $log)) { continue }
  $new = @(Get-Content -LiteralPath $log | Select-Object -Skip $before)
  foreach ($w in $want) { if (-not $found[$w]) { $hit = $new | Where-Object { $_ -match $w } | Select-Object -First 1; if ($hit) { $found[$w] = $hit; "after ${s}s: $hit" } } }
}
Start-Sleep -Seconds 3
'--- windows:'
Own | Where-Object { $_.MainWindowTitle } | ForEach-Object { "  pid $($_.Id): '$($_.MainWindowTitle)'" }
"processes: $((Own).Count)"
# a picture of the screen, for the artifact (a runner without a desktop gives a black one: not a failure)
try {
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  $b = [Windows.Forms.SystemInformation]::VirtualScreen
  $bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
  $gr = [Drawing.Graphics]::FromImage($bmp); $gr.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
  $bmp.Save((Join-Path $out "screen-$tag.png"), [Drawing.Imaging.ImageFormat]::Png); $gr.Dispose(); $bmp.Dispose()
  "screenshot: ci-out/screen-$tag.png ($($b.Width)x$($b.Height))"
} catch { "no screenshot: $($_.Exception.Message)" }
'--- new log lines:'
$new | Select-Object -First 60
Copy-Item -LiteralPath $log -Destination (Join-Path $out "overnight-$tag.log") -ErrorAction SilentlyContinue
Close-Own
"closed; still running: $((Own).Count)"
$miss = @($want | Where-Object { -not $found[$_] })
if ($miss.Count) { throw "no log line matching $($miss -join ' / ') within $Seconds s" }
"Overnight started ($tag): $($found.Count) of $($want.Count) proof lines found"
