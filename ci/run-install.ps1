# CI: run install.ps1 as a member's Claude does (a file, its own PowerShell), keep its log, check the exit code.
#   ci/run-install.ps1 -Run 1     first run: installs
#   ci/run-install.ps1 -Run 2     second run: must find everything in place and install nothing
#   ci/run-install.ps1 -Dry       test mode (OVERNIGHT_SETUP_DRY=1, the first thing AGENTS.md runs): must change nothing
param([int]$Run = 1, [switch]$Dry)
$ErrorActionPreference = 'Stop'
$out = Join-Path $env:GITHUB_WORKSPACE 'ci-out'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$log = Join-Path $env:TEMP 'overnight-setup\install.log'
if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
$env:OVERNIGHT_NO_OPEN = '1'
if ($Dry) { $env:OVERNIGHT_SETUP_DRY = '1'; $Run = 0 } else { Remove-Item Env:OVERNIGHT_SETUP_DRY -ErrorAction SilentlyContinue }
$watch = @("$env:ProgramFiles\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git", "$env:LOCALAPPDATA\Programs\overnight\Overnight.exe", "$env:LOCALAPPDATA\Programs\Python\Python312", "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe", "$env:LOCALAPPDATA\Programs\ffmpeg", "$env:USERPROFILE\.local\bin\claude.exe")
$had = @($watch | Where-Object { Test-Path -LiteralPath $_ })
$pathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
$t0 = Get-Date
& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $env:GITHUB_WORKSPACE 'install.ps1')
$code = $LASTEXITCODE
$min = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
Copy-Item -LiteralPath $log -Destination (Join-Path $out "install-run$Run.log") -ErrorAction SilentlyContinue
"install.ps1 run $Run ended with exit code $code after $min minutes"
if ($code -ne 0) { throw "install.ps1 run ${Run}: exit code $code (0 expected)" }
if ($Dry) {
  $new = @($watch | Where-Object { (Test-Path -LiteralPath $_) -and $had -notcontains $_ })
  if ($new.Count) { $new; throw 'test mode installed something' }
  if ([Environment]::GetEnvironmentVariable('Path', 'User') -ne $pathBefore) { throw 'test mode changed the user PATH' }
  if (-not (Select-String -LiteralPath $log -SimpleMatch 'Test mode finished: nothing was changed.' -Quiet)) { throw 'test mode did not end with its own line' }
  'test mode: nothing was installed or changed'
}
if ($Run -ge 2) {
  $did = @(Get-Content -LiteralPath $log | Where-Object { $_ -match 'Installing |Downloading ' })
  if ($did.Count) { $did; throw 'the second run installed something again: it should have found everything in place' }
  'second run: everything was already in place'
}
