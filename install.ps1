# Overnight installer for Windows: the tools Overnight needs, then Overnight itself.
#   irm https://raw.githubusercontent.com/nnovoselski04/overnight-releases/main/install.ps1 | iex
# Safe to run again: it skips what is already there, updates Overnight when a newer version is out, and puts back what
# is missing. Plain ASCII on purpose: Windows PowerShell 5.1 runs it through `irm | iex`.
#
# What it installs (each only when missing; winget first, the official download when winget can't):
#   git, ffmpeg, Python 3.12 (per user), the Microsoft Visual C++ Redistributable (x64), Claude Code, Overnight.
# Overnight finds git, ffmpeg and Python on the PATH or where these installers put them (src/main/system.js). Its Python
# packages (PyTorch, transcription, the image tools) go into its OWN Python environment, which the app makes itself:
# Home > Install your tools > Set up (= Settings > Set up everything), after the Skool login. This script never writes
# into Overnight's data.
#
# Switches (environment variables):
#   OVERNIGHT_SETUP_DRY=1    test mode: look and report, change nothing
#   OVERNIGHT_NO_OPEN=1      don't start Overnight at the end
#   OVERNIGHT_CLOSE_APP=1    the member said yes: an open Overnight may be closed to update it (only Overnight's own
#                            processes, found by their program path)
#   OVERNIGHT_REINSTALL=1    repair: install the newest Overnight again even when it is up to date (projects, settings
#                            and the Skool login stay)
#   OVERNIGHT_SETUP_NO_WINGET=1  tests only: skip winget, so the official downloads are what runs
# How it ends: 0 = all set; 3 = finished, with problems left (listed at the end); 1 = stopped (the reason is printed).
# Its output also goes to %TEMP%\overnight-setup\install.log.

& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try { [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials } catch { }

$Owner = 'nnovoselski04'
$Repo = 'overnight-releases'
$OneLine = "irm https://raw.githubusercontent.com/$Owner/$Repo/main/install.ps1 | iex"
$Dl = Join-Path $env:TEMP 'overnight-setup'
$LogFile = Join-Path $Dl 'install.log'
$DryRun = [bool]$env:OVERNIGHT_SETUP_DRY
$NoOpen = [bool]$env:OVERNIGHT_NO_OPEN
$CloseApp = $env:OVERNIGHT_CLOSE_APP -eq '1'
$Reinstall = $env:OVERNIGHT_REINSTALL -eq '1'
$Problems = New-Object System.Collections.ArrayList   # real problems: the run ends with code 3
$NextSteps = New-Object System.Collections.ArrayList  # what every member does next (not problems)

New-Item -ItemType Directory -Force -Path $Dl | Out-Null
function Put($t, $c) { Write-Host $t -ForegroundColor $c; try { Add-Content -LiteralPath $LogFile -Value $t -Encoding UTF8 } catch { } }
function Step($t) { Put '' White; Put "==> $t" White }
function Ok($t) { Put "    [ok] $t" Green }
function Note($t) { Put "    $t" DarkGray }
function Warn($t) { Put "    [!] $t" Yellow }
function Problem($t) { [void]$Problems.Add($t); Warn $t }
function Stop-Install($t) { Put '' White; Put "Install stopped: $t" Red; throw 'OVN_STOP' }
function Invoke-Native([scriptblock]$sb) { $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { & $sb } finally { $ErrorActionPreference = $eap } }
function Refresh-Path { $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') }
function Add-UserPath($dir) {
  $u = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not (($u -split ';') -contains $dir)) { [Environment]::SetEnvironmentVariable('Path', $(if ($u) { "$u;$dir" } else { $dir }), 'User') }
  Refresh-Path
}
function Find-Cmd($name) {
  # the Microsoft Store's python.exe alias only opens the Store: it doesn't count
  $c = Get-Command $name -All -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1
  if ($c) { return $c.Source } else { return $null }
}
function Ver($v) { try { $p = @((("$v" -replace '-.*$', '') -split '\.') + @('0', '0', '0'))[0..2]; [version]($p -join '.') } catch { [version]'0.0.0' } }
function Web-Get($url) {
  $c = (Invoke-WebRequest -Uri $url -UseBasicParsing).Content
  if ($c -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($c) }
  return [string]$c
}
function Web-File($url, $out) {
  # curl.exe (in Windows since 10 1803) is much faster for big files; Invoke-WebRequest when it is missing or fails
  if (Test-Path $out) { Remove-Item -LiteralPath $out -Force }
  $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
  if (Test-Path -LiteralPath $curl) {
    Invoke-Native { & $curl -fsSL --retry 3 --retry-delay 5 -o $out $url 2>&1 | Out-Null }
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $out)) { return }
    Note "curl.exe could not download it (code $LASTEXITCODE): trying again with PowerShell"
  }
  Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
}
function Get-Signed($url, $name) {
  # an installer this script runs must carry its publisher's valid signature
  $f = Join-Path $Dl $name
  Web-File $url $f
  $s = Get-AuthenticodeSignature -LiteralPath $f
  if ($s.Status -ne 'Valid') { throw "$name is not validly signed ($($s.Status))" }
  return $f
}
function Run-Installer($file, [string[]]$args2, $minutes) {
  # waits for this one process only: Start-Process -Wait would also wait for anything it starts (Overnight's own
  # installer starts the app)
  $p = Start-Process -FilePath $file -ArgumentList $args2 -PassThru
  $null = $p.Handle   # (keeps the exit code readable after the wait in PowerShell 5.1)
  if (-not $p.WaitForExit($minutes * 60000)) { throw "$([IO.Path]::GetFileName($file)) did not finish in $minutes minutes" }
  return $p.ExitCode
}

$HaveWinget = $false
function Winget-Install($id, [string[]]$extra) {
  # $true = installed or already there. --source winget: never the Store source (its pinned certificate fails behind
  # antivirus HTTPS scanning, VPNs and proxies)
  if (-not $HaveWinget) { return $false }
  Invoke-Native { winget install --id $id -e --source winget --silent --accept-source-agreements --accept-package-agreements --disable-interactivity @extra 2>&1 | Out-Null }
  $code = $LASTEXITCODE
  # 0 = installed; 0x8A15002B / 0x8A150061 = already installed, nothing newer
  if ($code -eq 0 -or $code -eq -1978335189 -or $code -eq -1978335135) { Refresh-Path; return $true }
  $why = if ($code -eq -1978335138) { ': something on this PC checks the internet traffic (an antivirus with HTTPS scanning, a VPN or a proxy)' } else { '' }
  Warn "winget could not install $id (code $code$why): using the official download instead"
  return $false
}
function Install-Tool($name, $id, [string[]]$extra, [scriptblock]$direct) {
  # $true = installed (or test mode); $false = a problem was recorded
  if ($DryRun) { Note "(test mode) would install $name"; return $true }
  Note "Installing $name ..."
  if (Winget-Install $id $extra) { Ok "$name installed (winget)"; return $true }
  try { & $direct; Refresh-Path; Ok "$name installed (official download)"; return $true }
  catch { Problem "$name did not install ($($_.Exception.Message)). Run this installer again; if it fails again, Overnight's own setup (Home > Install your tools > Set up) can install $name into its own folder."; return $false }
}

# ---- the official downloads (the winget fallback), all per user, no admin rights ----
function Direct-Git {
  $rel = Web-Get 'https://api.github.com/repos/git-for-windows/git/releases/latest' | ConvertFrom-Json
  $a = $rel.assets | Where-Object { $_.name -like 'Git-*-64-bit.exe' } | Select-Object -First 1
  if (-not $a) { throw 'no Git for Windows installer in its latest release' }
  $f = Get-Signed $a.browser_download_url 'git-setup.exe'
  $code = Run-Installer $f @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES', '/CURRENTUSER') 15
  if ($code -ne 0) { throw "the Git installer ended with code $code" }
  Add-UserPath (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd')
}
function Direct-Ffmpeg {
  # gyan.dev's release essentials build (linked from ffmpeg.org): the same files the Gyan.FFmpeg winget package has
  $zip = Join-Path $Dl 'ffmpeg.zip'
  Web-File 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' $zip
  $x = Join-Path $Dl 'ffmpeg-unpack'
  if (Test-Path -LiteralPath $x) { Remove-Item -LiteralPath $x -Recurse -Force }
  Expand-Archive -LiteralPath $zip -DestinationPath $x -Force
  $bin = Get-ChildItem -LiteralPath $x -Recurse -Filter 'ffmpeg.exe' | Select-Object -First 1
  if (-not $bin) { throw 'ffmpeg.exe is not in the download' }
  $dest = Join-Path $env:LOCALAPPDATA 'Programs\ffmpeg\bin'
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  Copy-Item (Join-Path $bin.DirectoryName '*') $dest -Force
  Add-UserPath $dest
}
function Direct-Python {
  # 3.12.10: the last Python 3.12 with a Windows installer. Per user (no admin), on the user PATH
  $f = Get-Signed 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe' 'python-setup.exe'
  $code = Run-Installer $f @('/quiet', 'InstallAllUsers=0', 'PrependPath=1', 'Include_test=0', 'Include_launcher=0') 15
  if ($code -ne 0) { throw "the Python installer ended with code $code" }
}
function Direct-VCRedist {
  # per machine: Windows asks the member for permission here
  $f = Get-Signed 'https://aka.ms/vs/17/release/vc_redist.x64.exe' 'vc_redist.x64.exe'
  $code = Run-Installer $f @('/install', '/quiet', '/norestart') 15
  # 3010 = installed, restart later; 1638 = a newer one is already there
  if ($code -ne 0 -and $code -ne 3010 -and $code -ne 1638) { throw "the installer ended with code $code" }
}
function VC-Installed {
  foreach ($k in @('HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64')) {
    try { if ((Get-ItemProperty -Path $k -Name Installed -ErrorAction SilentlyContinue).Installed -eq 1) { return $true } } catch { }
  }
  return $false
}

# ---- git and ffmpeg: where Overnight looks (system.js installedCopies) ----
function Find-Git {
  $g = Find-Cmd 'git'; if ($g) { return $g }
  foreach ($p in @("$env:ProgramFiles\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) { if (Test-Path -LiteralPath $p) { return $p } }
  return $null
}
function Find-Ffmpeg {
  $f = Find-Cmd 'ffmpeg'; if ($f) { return $f }
  $l = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ffmpeg.exe'; if (Test-Path -LiteralPath $l) { return $l }
  $pk = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
  if (Test-Path -LiteralPath $pk) { $b = Get-ChildItem -LiteralPath $pk -Directory -Filter 'Gyan.FFmpeg*' -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue } | Select-Object -First 1; if ($b) { return $b.FullName } }
  return $null
}

# ---- Python: the one Overnight will use, the way it picks it (system.js adopt): the Python in its settings, the first
# `python` on the PATH, then %LOCALAPPDATA%\Programs\Python\Python3xx. It takes any 3.10+; its packages (PyTorch,
# faster-whisper) are known to work on 3.10 to 3.13, 64-bit, not conda ----
$PyProbe = "import sys, struct, os`nprint('OVPY %d.%d %d %s %s' % (sys.version_info[0], sys.version_info[1], struct.calcsize('P') * 8, 'conda' if os.path.exists(os.path.join(sys.prefix, 'conda-meta')) else 'plain', sys.executable.encode('utf-8').hex()))"
function Probe-Python($exe) {
  $l = $null
  try { $l = @(Invoke-Native { $PyProbe | & $exe - 2>$null | ForEach-Object { "$_" } }) | Where-Object { $_ -match '^OVPY ' } | Select-Object -Last 1 } catch { $l = $null }
  if (-not $l) { return $null }
  $f = $l.Trim() -split ' ', 5
  $v = Ver $f[1]
  $hex = "$($f[4])".Trim(); $b = New-Object byte[] ([int]($hex.Length / 2))
  try { for ($k = 0; $k -lt $b.Length; $k++) { $b[$k] = [Convert]::ToByte($hex.Substring(2 * $k, 2), 16) } } catch { return $null }
  $why = $null
  if ($v.Major -ne 3 -or $v.Minor -lt 10 -or $v.Minor -gt 13) { $why = "Python $($f[1])" }
  elseif ($f[2] -ne '64') { $why = "32-bit Python $($f[1])" }
  elseif ($f[3] -eq 'conda') { $why = "a conda Python ($($f[1]))" }
  return @{ ver = $f[1]; exe = [Text.Encoding]::UTF8.GetString($b); appTakes = ($v.Major -eq 3 -and $v.Minor -ge 10); why = $why }
}
function App-SettingsPython {
  # read only: the Python named in Overnight's settings, when it names a full path
  $f = Join-Path $env:APPDATA 'Overnight\settings.json'
  try { if (Test-Path -LiteralPath $f) { $p = ([IO.File]::ReadAllText($f) | ConvertFrom-Json).tools.python; if ($p -and [IO.Path]::IsPathRooted([string]$p)) { return [string]$p } } } catch { }
  return $null
}
function Find-AppPython {
  # @{ exe; ver; why; how } of the Python Overnight would use now, or $null
  $c = @()
  $set = App-SettingsPython; if ($set -and (Test-Path -LiteralPath $set)) { $c += , @($set, 'its settings') }
  $first = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($first) { $c += , @($first.Source, 'the PATH') }
  $root = Join-Path $env:LOCALAPPDATA 'Programs\Python'
  if (Test-Path -LiteralPath $root) { Get-ChildItem -LiteralPath $root -Directory | Where-Object { $_.Name -match '^Python3\d+$' } | Sort-Object Name -Descending | ForEach-Object { $e = Join-Path $_.FullName 'python.exe'; if (Test-Path -LiteralPath $e) { $c += , @($e, 'its install folder') } } }
  foreach ($x in $c) { $r = Probe-Python $x[0]; if ($r -and $r.appTakes) { $r.how = $x[1]; return $r } }
  return $null
}

# ---- Overnight itself ----
function Find-AppDir {
  # where the installer put it (its uninstall entry), else the default per-user folder
  foreach ($k in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    $e = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'Overnight' -and $_.InstallLocation } | Select-Object -First 1
    if ($e -and (Test-Path -LiteralPath (Join-Path $e.InstallLocation 'Overnight.exe'))) { return [string]$e.InstallLocation.TrimEnd('\') }
  }
  return (Join-Path $env:LOCALAPPDATA 'Programs\overnight')
}
function App-Version($exe) {
  if (-not (Test-Path -LiteralPath $exe)) { return $null }
  $v = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
  if ($v -match '^\d+\.\d+\.\d+\.\d+$') { $v = $v -replace '\.\d+$', '' }
  if (-not $v -or $v -eq '0.0.0') { return $null }
  return $v
}
function App-Procs($exe) { @(Get-Process -Name 'Overnight' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -ieq $exe }) }
function Latest-Release {
  # the release's own update file: version, installer file name, sha512 (no GitHub API rate limit)
  try { $yml = Web-Get "https://github.com/$Owner/$Repo/releases/latest/download/latest.yml" } catch { return $null }
  $r = @{ version = [regex]::Match($yml, '(?m)^version:\s*(\S+)').Groups[1].Value; file = [regex]::Match($yml, '(?m)^path:\s*(\S+)').Groups[1].Value; sha512 = [regex]::Match($yml, '(?m)^sha512:\s*(\S+)').Groups[1].Value }
  if ($r.version -and $r.file) { return $r } else { return $null }
}

$stopped = $false
try {
Put 'Overnight installer (Windows)' White
Note 'Installs git, ffmpeg, Python 3.12, the Visual C++ Redistributable, Claude Code and Overnight. Takes 5-20 minutes.'
Note "Output is also written to $LogFile"
if ($DryRun) { Warn 'Test mode (OVERNIGHT_SETUP_DRY): nothing is installed or changed.' }

# ---- this computer ----
Step 'This computer'
if ($env:OS -ne 'Windows_NT') { Stop-Install 'this installer is for Windows. A Mac version of Overnight is coming.' }
if (-not [Environment]::Is64BitOperatingSystem) { Stop-Install 'Overnight needs 64-bit Windows 10 or 11.' }
$build = [Environment]::OSVersion.Version.Build
if ($build -lt 17763) { Stop-Install 'Overnight needs Windows 10 (version 1809) or newer.' }
Ok "Windows build $build, 64-bit, $env:PROCESSOR_ARCHITECTURE"
# inside an app package (an MSIX app's shell, like some Claude desktop apps), Windows keeps what this script writes into
# AppData in that app's private copy: Overnight and its Start menu entry would be invisible to the member
try {
  Add-Type -Namespace OvnSetup -Name Pkg -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern int GetCurrentPackageFullName(ref int length, System.Text.StringBuilder name);' -ErrorAction Stop
  $n = 0
  if ([OvnSetup.Pkg]::GetCurrentPackageFullName([ref]$n, $null) -ne 15700) {
    Stop-Install "this PowerShell runs inside an app package, so what it installs would only be visible inside that app. Open PowerShell yourself (Start menu, type PowerShell, press Enter) and paste: $OneLine"
  }
  Ok 'not inside an app package'
} catch { if ("$_" -eq 'OVN_STOP') { throw } ; Note "could not check for an app package ($($_.Exception.Message))" }
$free = $null; try { $free = [math]::Round((Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free / 1GB, 1) } catch { }
if ($null -ne $free) { if ($free -lt 10) { Warn "only $free GB free on $env:SystemDrive. Overnight and its tools need about 6 GB, its videos more." } else { Ok "$free GB free on $env:SystemDrive" } }
$sac = $null
try { $sac = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState' -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState } catch { }
if ($sac -eq 1) { Warn 'Smart App Control is On. It can block the Python packages Overnight uses (transcription, WinError 4551). Turning it off is your decision: Windows Security > App & browser control > Smart App Control.' }

Step 'Windows Package Manager (winget)'
Refresh-Path
if ($env:OVERNIGHT_SETUP_NO_WINGET -eq '1') { Warn 'winget skipped (OVERNIGHT_SETUP_NO_WINGET, a test): the official downloads are used.' }
elseif (Get-Command winget -ErrorAction SilentlyContinue) { $HaveWinget = $true; Ok 'winget is available' }
else { Warn 'winget is not available: the tools come from their official downloads instead (that works too).' }

# ---- git, ffmpeg, Python ----
Step 'git, ffmpeg and Python'
$g = Find-Git
if ($g) { Ok "git already installed ($g)" }
elseif ((Install-Tool 'git' 'Git.Git' @('--scope', 'user') { Direct-Git }) -and -not $DryRun) {
  $g = Find-Git; if ($g) { Note "git: $g" } else { Problem 'git was installed but is not found. Open a new PowerShell window and run this installer again.' }
}
$f = Find-Ffmpeg
if ($f) { Ok "ffmpeg already installed ($f)" }
elseif ((Install-Tool 'ffmpeg' 'Gyan.FFmpeg' @() { Direct-Ffmpeg }) -and -not $DryRun) {
  $f = Find-Ffmpeg; if ($f) { Note "ffmpeg: $f" } else { Problem 'ffmpeg was installed but is not found. Open a new PowerShell window and run this installer again.' }
}

$py = Find-AppPython
if ($py -and -not $py.why) { Ok "Python $($py.ver) already installed: Overnight will use $($py.exe) (from $($py.how))" }
else {
  if ($py) { Warn "Overnight would use $($py.exe) (from $($py.how)): $($py.why), on which its packages may not install. Python 3.12 goes next to it (that one stays as it is)." }
  $pyDone = Install-Tool 'Python 3.12' 'Python.Python.3.12' @('--scope', 'user') { Direct-Python }
  if (-not $DryRun -and $pyDone) {
    $py = Find-AppPython
    if (-not $py) { Problem 'Python 3.12 was installed but does not start. Open a new PowerShell window and run this installer again; if it shows again, restart the computer first.' }
    elseif ($py.why) {
      $p312 = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
      Problem "Overnight would still use $($py.exe) ($($py.why)). After the Skool login, in Overnight's Settings > Tool paths, set Python to $p312, then Home > Install your tools > Set up."
    } else { Ok "Overnight will use Python $($py.ver): $($py.exe)" }
  }
}

# ---- Microsoft Visual C++ Redistributable (x64): PyTorch (transcription) fails without it (WinError 1114, c10.dll) ----
Step 'Microsoft Visual C++ Redistributable (x64)'
if (VC-Installed) { Ok 'already installed' }
elseif ($DryRun) { Note '(test mode) would install it (Windows asks for permission)' }
else {
  Note 'Installing it. Windows may ask "Do you want to allow this app to make changes to your device?": press Yes.'
  $vcOk = Winget-Install 'Microsoft.VCRedist.2015+.x64' @()
  if (-not $vcOk) { try { Direct-VCRedist; $vcOk = $true } catch { Note "the official download did not install either ($($_.Exception.Message))" } }
  if ($vcOk -and (VC-Installed)) { Ok 'installed' }
  else { Problem 'The Microsoft Visual C++ Redistributable (x64) is not installed (the permission box was declined?). Transcription needs it: open https://aka.ms/vs/17/release/vc_redist.x64.exe, run it and press Yes.' }
}

# ---- Claude Code: the official installer, only when it is missing ----
Step 'Claude Code'
$claudeHome = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
$cl = Find-Cmd 'claude'; if (-not $cl -and (Test-Path -LiteralPath $claudeHome)) { $cl = $claudeHome }
if ($cl) { Ok "Claude Code already installed ($cl)" }
elseif ($DryRun) { Note '(test mode) would install Claude Code (https://claude.ai/install.ps1)' }
else {
  Note 'Installing Claude Code (its official installer, https://claude.ai/install.ps1) ...'
  $why = $null
  try {
    $cs = Web-Get 'https://claude.ai/install.ps1'
    if ($cs -match '(?i)<html') { $why = 'claude.ai sent a web page instead of its installer (a Wi-Fi that wants a login first, or a web filter)' }
    else {
      # in a process of its own, so an `exit` in it can't end this script
      $cf = Join-Path $Dl 'claude-install.ps1'
      [IO.File]::WriteAllText($cf, $cs, (New-Object Text.UTF8Encoding $false))
      $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
      Invoke-Native { & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $cf 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -and $_ -notmatch '^#< CLIXML|^<Objs ' } | ForEach-Object { Note $_ } }
    }
  } catch { $why = "claude.ai could not be reached ($($_.Exception.Message))" }
  Refresh-Path
  $cl = Find-Cmd 'claude'; if (-not $cl -and (Test-Path -LiteralPath $claudeHome)) { $cl = $claudeHome }
  if ($cl) { Ok "Claude Code installed ($cl)" }
  else { Warn "Claude Code did not install$(if ($why) { ": $why" } else { ' (its own lines are above)' }). Overnight uses the copy of Claude Code built into it until then; run this installer again once https://claude.ai opens in your browser." }
}

# Claude Code's installer leaves its folder off the PATH and asks for it to be added: the same, done here, so `claude`
# works in a new terminal (Overnight itself finds it there either way)
$clDir = Split-Path $claudeHome
if (-not $DryRun -and $cl -eq $claudeHome -and -not (([Environment]::GetEnvironmentVariable('Path', 'User') -split ';') -contains $clDir)) { Add-UserPath $clDir; Note "added $clDir to your PATH, so 'claude' works in a new terminal" }

# ---- Overnight ----
Step 'Overnight'
$AppDir = Find-AppDir
$AppExe = Join-Path $AppDir 'Overnight.exe'
$current = App-Version $AppExe
$latest = Latest-Release
if (-not $latest) {
  if ($current) { Problem "could not reach https://github.com/$Owner/$Repo/releases, so Overnight $current was not checked for an update." }
  else { Stop-Install "could not reach https://github.com/$Owner/$Repo/releases (no internet, or a firewall, proxy or VPN blocks github.com). Nothing of Overnight was changed: run this installer again." }
}
if ($current -and (-not $latest -or ((Ver $current) -ge (Ver $latest.version) -and -not $Reinstall))) { Ok "Overnight $current is installed and up to date ($AppExe)" }
elseif ($DryRun) { Note "(test mode) would $(if ($current -and $Reinstall -and (Ver $current) -ge (Ver $latest.version)) { 'install again: Overnight' } elseif ($current) { "update Overnight $current to" } else { 'install Overnight' }) $($latest.version)" }
else {
  $target = $latest.version
  $open = App-Procs $AppExe
  if ($open.Count -and $CloseApp) {
    Note 'Overnight is open: closing it (you said yes) ...'
    $open | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 30 -and (App-Procs $AppExe).Count; $i++) { Start-Sleep -Milliseconds 500 }
    $open = App-Procs $AppExe
  }
  if ($open.Count) { Problem "Overnight $current is open, so it was not updated to $target. Close it and run this installer again (or it updates itself when you close it)." }
  else {
    $setup = Join-Path $Dl $latest.file
    Note "Downloading Overnight $target (about 750 MB) ..."
    try { Web-File "https://github.com/$Owner/$Repo/releases/download/v$target/$($latest.file)" $setup }
    catch {
      try { Web-File "https://github.com/$Owner/$Repo/releases/latest/download/Overnight-Setup.exe" $setup }
      catch { Stop-Install "the download of Overnight $target failed ($($_.Exception.Message)). Nothing was changed: check the internet connection and run this installer again." }
    }
    if ($latest.sha512) {
      $h = [Security.Cryptography.SHA512]::Create(); $s = [IO.File]::OpenRead($setup)
      try { $got = [Convert]::ToBase64String($h.ComputeHash($s)) } finally { $s.Dispose() }
      if ($got -ne $latest.sha512) { Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue; Stop-Install "the download of Overnight $target was damaged on the way (it does not match the release), so it was not run. Run this installer again; if it shows again, an antivirus's web scanning or a proxy changes downloads." }
      Ok 'download checked against the release (sha512)'
    }
    Note 'Installing (per user, no admin rights) ...'
    $code = Run-Installer $setup @('/S') 15
    Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue
    $AppDir = Find-AppDir; $AppExe = Join-Path $AppDir 'Overnight.exe'
    $now = App-Version $AppExe
    if ($code -ne 0 -or -not $now) { Stop-Install "the Overnight installer did not finish (code $code). An antivirus may have blocked it: check its quarantine, then run this installer again." }
    if ((Ver $now) -ne (Ver $target)) { Problem "Overnight says version $now after installing $target. Restart the computer and run this installer again." }
    else { Ok "Overnight $now installed$(if ($current) { " (was $current)" }) in $AppDir" }
  }
}

# ---- done ----
Step 'Done'
[void]$NextSteps.Add('In the Overnight window, log in with Skool: the account you joined the Overnight community with (https://www.skool.com/overnight-ai-video-automation-5588).')
[void]$NextSteps.Add('On the Home page, Connect Claude: click Sign in (your own Claude account).')
[void]$NextSteps.Add('Then Install your tools: click Set up. Overnight installs its Python packages (about 2 GB with PyTorch) and its packs itself; transcription then sets itself up.')
if (-not $DryRun -and -not $NoOpen -and (Test-Path -LiteralPath $AppExe)) {
  if ((App-Procs $AppExe).Count) { Ok 'Overnight is open' }
  else { Start-Process -FilePath $AppExe; Ok 'Opening Overnight' }
}
Note 'Your videos will live in Documents\Overnight.'
Put '' White
Put 'Next:' White
foreach ($t in $NextSteps) { Put "  - $t" White }
Put '' White
if ($Problems.Count) {
  Put "Finished, with $($Problems.Count) problem(s) left:" Yellow
  foreach ($t in $Problems) { Put "  - $t" Yellow }
  Put 'Run the same command again any time to update or repair.' White
} else { Put 'All set. Run the same command again any time to update or repair.' White }
}
catch {
  $stopped = $true
  if ("$_" -ne 'OVN_STOP') { Put '' White; Put "Install stopped: $_" Red }
}
$code = if ($stopped) { 1 } elseif ($Problems.Count) { 3 } else { 0 }
# run as a file: the exit code. Through irm | iex: $LASTEXITCODE only (`exit` would close the member's window)
if ($PSCommandPath) { exit $code }
$global:LASTEXITCODE = $code
}
