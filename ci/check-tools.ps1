# CI: after install.ps1, does each tool resolve the way Overnight looks for it (a fresh PATH, as a new process has),
# and is the app where its installer puts it?
$ErrorActionPreference = 'Stop'
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$fail = @()
# (all output first, then its first line: Select-Object -First 1 in the pipe would stop the program early)
function Native($exe, [string[]]$a) { $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { $o = @(& $exe @a 2>&1 | ForEach-Object { "$_" }); return @{ code = $LASTEXITCODE; out = $(if ($o.Count) { $o[0] } else { '' }) } } finally { $ErrorActionPreference = $eap } }

$git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($git) { $r = Native $git.Source @('--version'); "git     $($git.Source): $($r.out)"; if ($r.code -ne 0) { $fail += 'git does not run' } } else { $fail += 'git is not on the PATH' }

$ff = Get-Command ffmpeg -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $ff) { $l = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ffmpeg.exe'; if (Test-Path $l) { $ff = Get-Item $l | Select-Object @{ n = 'Source'; e = { $_.FullName } } } }
if ($ff) { $r = Native $ff.Source @('-hide_banner', '-version'); "ffmpeg  $($ff.Source): $($r.out)"; if ($r.code -ne 0) { $fail += 'ffmpeg does not run' } } else { $fail += 'ffmpeg not found' }

# Python: what the app's check runs first is the first `python` on the PATH; else %LOCALAPPDATA%\Programs\Python\Python3xx
$py = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$pyExe = $null
if ($py) { $r = Native $py.Source @('--version'); "python  $($py.Source): $($r.out)"; if ($r.code -eq 0 -and $r.out -match 'Python 3\.1[0-3]') { $pyExe = $py.Source } }
if (-not $pyExe) {
  $c = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs\Python') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^Python3\d+$' } | Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'python.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($c) { $r = Native $c @('--version'); "python  $c (install folder): $($r.out)"; if ($r.code -eq 0 -and $r.out -match 'Python 3\.1[0-3]') { $pyExe = $c } }
}
if (-not $pyExe) { $fail += 'no Python 3.10-3.13 where Overnight looks' }
else { $r = Native $pyExe @('-c', 'import venv, ensurepip, ssl; print(1)'); "python  venv/ensurepip/ssl import: $($r.out)"; if ($r.code -ne 0) { $fail += 'Python cannot make a venv (Overnight makes its own)' } }

$cl = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$clExe = if ($cl) { $cl.Source } elseif (Test-Path "$env:USERPROFILE\.local\bin\claude.exe") { "$env:USERPROFILE\.local\bin\claude.exe" } else { $null }
if ($clExe) { $r = Native $clExe @('--version'); "claude  ${clExe}: $($r.out)"; if ($r.code -ne 0) { $fail += 'claude does not run' } } else { $fail += 'Claude Code not found' }

$vc = $false
foreach ($k in 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64') { try { if ((Get-ItemProperty -Path $k -Name Installed -ErrorAction SilentlyContinue).Installed -eq 1) { $vc = $true } } catch { } }
"vc++    x64 runtime installed: $vc"; if (-not $vc) { $fail += 'VC++ redistributable missing' }

'--- %LOCALAPPDATA%\Programs:'
Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs') -Directory | ForEach-Object { "  $($_.Name)" }
$u = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'Overnight' } | Select-Object -First 1
"uninstall entry: $(if ($u) { "$($u.DisplayName) $($u.DisplayVersion) at $($u.InstallLocation)" } else { 'none' })"
$exe = Join-Path $env:LOCALAPPDATA 'Programs\overnight\Overnight.exe'
if (Test-Path -LiteralPath $exe) { "app     $exe, version $((Get-Item $exe).VersionInfo.ProductVersion)" } else { $fail += "Overnight.exe is not at $exe" }
$lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Overnight.lnk'
"start menu shortcut: $(Test-Path -LiteralPath $lnk)"

if ($fail.Count) { $fail | ForEach-Object { "FAIL: $_" }; throw "$($fail.Count) check(s) failed" }
'all tools resolve; the app is installed'
