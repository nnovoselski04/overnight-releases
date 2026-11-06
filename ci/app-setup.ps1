# CI: the app's own "Set up everything" rows, run by the installed app itself without its window
# (its --selftest=setuprun test mode, in a scratch folder), on top of what install.ps1 installed. Proves that Overnight picks up the
# git, ffmpeg and Python that install.ps1 put there and can make its own Python environment and packages on them.
#   ci/app-setup.ps1 -Ids packages
param([string]$Ids = 'packages', [int]$Minutes = 45)
$ErrorActionPreference = 'Stop'
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$out = Join-Path $env:GITHUB_WORKSPACE 'ci-out'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$exe = Join-Path $env:LOCALAPPDATA 'Programs\overnight\Overnight.exe'
# (a selftest keeps its own scratch folder in %TEMP%, never the member profile: overnight-selftest-app.asar\profile)
$prof = Join-Path $env:TEMP 'overnight-selftest-app.asar\profile'
$env:OVERNIGHT_SETUP_NO_CHAT = '1'   # a failed row must not start the setup chat (an unattended Claude with a shell)
$so = Join-Path $out "app-setup-$($Ids -replace ',', '-').txt"; $se = "$so.err"
"running $exe --selftest=setuprun --ids=$Ids, up to $Minutes minutes"
$p = Start-Process -FilePath $exe -ArgumentList '--selftest=setuprun', "--ids=$Ids" -PassThru -RedirectStandardOutput $so -RedirectStandardError $se
$null = $p.Handle
$done = $p.WaitForExit($Minutes * 60000)
if (-not $done) { try { $p.Kill() } catch { } }
Get-Content -LiteralPath $so -ErrorAction SilentlyContinue | Where-Object { $_ -match '\[selftest\]' }
$err = @(Get-Content -LiteralPath $se -ErrorAction SilentlyContinue | Where-Object { $_ -and $_ -notmatch 'GPU|gpu_|Gpu' } | Select-Object -Last 15)
if ($err.Count) { '--- stderr (last lines):'; $err }
if (-not $done) { throw "the app's setup did not finish in $Minutes minutes" }
"exit code $($p.ExitCode)"
if ($p.ExitCode -ne 0) { throw "the app's own setup ($Ids) failed: exit code $($p.ExitCode)" }
$py = Join-Path $prof 'python\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $py)) { $alt = Get-ChildItem -Path (Join-Path $env:TEMP 'overnight-selftest-*\profile\python\Scripts\python.exe') -ErrorAction SilentlyContinue | Select-Object -First 1; if ($alt) { $py = $alt.FullName; $prof = Split-Path (Split-Path (Split-Path $py)) } }
Copy-Item -LiteralPath (Join-Path $prof 'logs\overnight.log') -Destination (Join-Path $out 'overnight-app-setup.log') -ErrorAction SilentlyContinue
"its scratch profile: $prof"
if ($Ids -match 'packages') {
  if (-not (Test-Path -LiteralPath $py)) { throw "the app's own Python environment is not at $py" }
  # the packages every version so far installs (the app's own check above is the full list of its version); importing
  # torch also proves the Visual C++ runtime is there
  $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  & $py -c "import numpy, scipy, PIL, stable_whisper, faster_whisper, torch, onnxruntime, cv2, vtracer; print('imports ok, torch', torch.__version__)" 2>&1 | ForEach-Object { "$_" }
  $c = $LASTEXITCODE; $ErrorActionPreference = $eap
  if ($c -ne 0) { throw "the app's Python environment does not import its packages (exit $c)" }
}
"the app's own setup ($Ids) passed"
