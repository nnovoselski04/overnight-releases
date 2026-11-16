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
#   OVERNIGHT_INSTALL_DIR=E:\Overnight   install on another drive: the app in <dir>\app; on a first install the tools and
#                            data in <dir>\data and new videos in <dir>\videos. Used on a first install or with
#                            OVERNIGHT_REINSTALL=1; an update keeps the folder Overnight is already in
#   OVERNIGHT_SETUP_NO_WINGET=1  tests only: skip winget, so the official downloads are what runs
#   OVERNIGHT_TEST_RELEASE_BASE=<folder>  tests only (ci\test-complete-install.ps1): the release files come from that
#                            folder, its fake-installer.ps1 stands in for the installer, OVERNIGHT_TEST_APPDIR is the install
#                            folder, OVERNIGHT_TEST_FREE_GB the free space, and only the Overnight step runs
# Overnight's own files (16 Nov 2026, after updates to 0.5.0 that left files out): before it installs, the disks must
# have room (else it stops with the numbers, nothing changed); the download must match the release's SHA256SUMS.txt;
# after it installs, every file is checked against the version's list (resources\install-manifest.json, or for 0.5.0
# install-manifest-0.5.0.json on its release page); an incomplete install is removed (the program folder only, never the
# data or the videos) and installed once more. An installed Overnight with files missing is installed again even when it
# is the newest version.
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
$InstallRoot = if ($env:OVERNIGHT_INSTALL_DIR) { [IO.Path]::GetFullPath($env:OVERNIGHT_INSTALL_DIR.Trim().Trim('"')) } else { $null }
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
  if ($TestBase -and $file -like '*Overnight-Setup*') { $args2 = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $TestBase 'fake-installer.ps1'), '-Setup', $file, '-Dir', $AppDir); $file = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }   # (a test: its fake installer)
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
  if ($TestBase -and $env:OVERNIGHT_TEST_APPDIR) {
    $t = [IO.Path]::GetFullPath($env:OVERNIGHT_TEST_APPDIR).TrimEnd('\')
    if ($t -match 'Programs\\overnight$') { throw "OVERNIGHT_TEST_APPDIR may not be a real Overnight folder ($t)" }
    return $t
  }
  # where the installer put it, else the default per-user folder. electron-builder keeps that folder in
  # HKCU\Software\<app GUID>\InstallLocation: its uninstall entry (key name = the same GUID) has no InstallLocation, so the
  # old lookup never matched and a custom-folder install (OVERNIGHT_INSTALL_DIR, e.g. on D:) looked "not installed".
  # The uninstall entry's UninstallString points into the folder too
  foreach ($e in @(Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'Overnight' })) {
    $dirs = @()
    $loc = (Get-ItemProperty -LiteralPath ('HKCU:\Software\' + $e.PSChildName) -ErrorAction SilentlyContinue).InstallLocation
    if ($loc) { $dirs += [string]$loc }
    if ($e.InstallLocation) { $dirs += [string]$e.InstallLocation }
    if ($e.UninstallString -match '^"(.+)\\[^\\"]+\.exe"') { $dirs += $Matches[1] }
    foreach ($d in $dirs) { if (Test-Path -LiteralPath (Join-Path $d 'Overnight.exe')) { return $d.TrimEnd('\') } }
    # (an update that stopped after moving the old version aside: Recover-Aside puts it back)
    foreach ($d in $dirs) { if (Test-Path -LiteralPath (Join-Path ($d.TrimEnd('\') + '.ovn-old') 'Overnight.exe')) { return $d.TrimEnd('\') } }
  }
  return (Join-Path $env:LOCALAPPDATA 'Programs\overnight')
}
# ---- an update moves the installed version aside first (same drive: each move is one rename, the files inside are not
# touched), the installer puts the new version into the emptied folder, and the old one is deleted after that worked or
# put back when it didn't. The old version's own uninstaller then has nothing to move: it used to move every file into
# %TEMP%, which stopped the update with code 2 ("Failed to uninstall old application files") when a path got past
# Windows' 260 characters there (Crayon's Chrome in resources\stylepacks, 0.4.6 to 0.4.9) or a file was in use, and
# copied a D: install to C: first. The move: the whole folder in one rename, or, when Windows refuses that because some
# program has the folder as its working folder (anything Overnight opened inherits it: Windows Photos for a rendered
# video, a player, Explorer; they outlive the app), its entries one by one. This works with every Overnight installer,
# 0.4.9's included. Installers after 0.4.9 do the same themselves (build/installer.nsh)
function Long-Path($p) { if ($p.StartsWith('\\')) { '\\?\UNC\' + $p.Substring(2) } else { '\\?\' + $p } }
function Remove-Tree($p) {
  # rd by a \\?\ path: no length limit. A folder that is some program's working folder stays, empty
  if (Test-Path -LiteralPath $p) { Invoke-Native { & (Join-Path $env:SystemRoot 'System32\cmd.exe') /c rd /s /q "$(Long-Path $p)" 2>&1 | Out-Null } }
}
function App-Only($dir) {
  # only what an Overnight install puts there, so moving and deleting the folder can never take a member's own files
  foreach ($e in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)) {
    if ($e.PSIsContainer) { if (@('resources', 'locales', 'swiftshader') -notcontains $e.Name) { return $false } }
    elseif (@('.exe', '.dll', '.pak', '.dat', '.bin', '.json', '.txt', '.html', '.ico', '.log') -notcontains $e.Extension.ToLower()) { return $false }
  }
  return $true
}
function Folder-Procs($dir) {
  # every program running from the folder: Overnight, and its Chrome, Claude Code or render helpers left behind
  $pre = $dir.TrimEnd('\') + '\'
  @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase) })
}
function Move-Entries($src, $dst, $depth = 0) {
  # the entries of $src into $dst, one rename each; a folder that refuses (someone's working folder, or one above it) is
  # entered and stays behind empty. Returns the first entry that would not move (a file really in use), $null = all moved
  $bad = $null
  for ($pass = 0; $pass -lt 4; $pass++) {
    $bad = $null; $moved = 0
    foreach ($e in @(Get-ChildItem -LiteralPath $src -Force -ErrorAction SilentlyContinue)) {
      $to = Join-Path $dst $e.Name
      try { if ($e.PSIsContainer) { [IO.Directory]::Move($e.FullName, $to) } else { [IO.File]::Move($e.FullName, $to) }; $moved++ }
      catch {
        if ($e.PSIsContainer -and $depth -lt 16) { [void][IO.Directory]::CreateDirectory($to); $b = Move-Entries $e.FullName $to ($depth + 1); if ($b -and -not $bad) { $bad = $b } }
        elseif (-not $bad) { $bad = $e.FullName }
      }
    }
    if (-not $moved) { break }
  }
  return $bad
}
function Put-Back($aside, $dir, $exe = 'Overnight.exe') {
  # the old version back where it was: the half-installed files go, then the aside folder in one rename, or its entries
  # one by one into a folder some program still works in
  if (-not $aside -or -not (Test-Path -LiteralPath (Join-Path $aside $exe))) { return $false }
  Remove-Tree $dir
  try { [IO.Directory]::Move($aside, $dir) }
  catch {
    [void][IO.Directory]::CreateDirectory($dir)
    $bad = Move-Entries $aside $dir
    if ($bad) {
      [IO.File]::WriteAllText((Join-Path $aside '.ovn-moved'), $dir)
      Warn "could not put the old version back completely ($bad would not move): the next run of this installer does it"
      return $false
    }
    Remove-Tree $aside
  }
  Remove-Item -LiteralPath (Join-Path $dir '.ovn-moved') -Force -ErrorAction SilentlyContinue
  return $true
}
function Recover-Aside($dir, $exe = 'Overnight.exe') {
  # an earlier run that stopped between the move and the end of the install (marked, or the app is only in the aside
  # folder): the old version goes back first. Otherwise the old files of an update that worked
  $aside = "$dir.ovn-old"
  if (-not (Test-Path -LiteralPath $aside)) { return }
  if ((Test-Path -LiteralPath (Join-Path $aside $exe)) -and ((Test-Path -LiteralPath (Join-Path $aside '.ovn-moved')) -or -not (Test-Path -LiteralPath (Join-Path $dir $exe)))) {
    Note "an earlier update stopped half way: putting the version it had moved aside back ($dir)"
    [void](Put-Back $aside $dir $exe)
  } elseif (-not (Test-Path -LiteralPath (Join-Path $aside '.ovn-moved'))) { Remove-Tree $aside }
}
function Move-OldApp($dir, $exe = 'Overnight.exe') {
  # the aside folder, or $null when the folder holds other files too (then the old version's uninstaller removes it, as
  # before). Stops the install, with nothing changed, when another program really holds a file in the folder
  if (-not (App-Only $dir)) { Note "$dir holds files Overnight did not put there: the old version's own uninstaller removes it"; return $null }
  $aside = "$dir.ovn-old"
  Remove-Tree $aside
  $how = $null
  for ($i = 0; $i -lt 4 -and -not $how; $i++) {
    try { [IO.Directory]::Move($dir, $aside); $how = 'in one rename' } catch { Start-Sleep -Seconds 1 }
  }
  if (-not $how) {
    # refused: a program works in the folder (or holds a file). Its entries, marked first so a run that dies half way is
    # put back by the next one
    [void][IO.Directory]::CreateDirectory($aside)
    [IO.File]::WriteAllText((Join-Path $aside '.ovn-moved'), $dir)
    $bad = Move-Entries $dir $aside
    if ($bad) {
      $back = Move-Entries $aside $dir
      if (-not $back) { Remove-Item -LiteralPath (Join-Path $dir '.ovn-moved') -Force -ErrorAction SilentlyContinue; Remove-Tree $aside }
      else { [IO.File]::WriteAllText((Join-Path $aside '.ovn-moved'), $dir) }   # (the next run of this installer puts the rest back)
      $p = @(Folder-Procs $dir | ForEach-Object { $_.Name -replace '\.exe$', '' } | Select-Object -Unique)
      if ($p.Count) { Stop-Install "Overnight was not updated: $($p -join ', ') is using a file in its folder ($bad). Close it, then run this installer again. Nothing was changed: the version you have still works." }
      Stop-Install "Overnight was not updated: another program is using a file in its folder ($bad). Close that program, then run this installer again (if you can't find it, restart the computer first). Nothing was changed: the version you have still works."
    }
    $how = 'entry by entry (a program works in that folder)'
  }
  [IO.File]::WriteAllText((Join-Path $aside '.ovn-moved'), $dir)
  Note "moved the installed version aside $how ($aside): it is deleted once the new one is in"
  return $aside
}
function App-Version($exe) {
  if (-not (Test-Path -LiteralPath $exe)) { return $null }
  if ($TestBase) { $vf = Join-Path (Split-Path $exe) 'version.txt'; if (Test-Path -LiteralPath $vf) { return ([IO.File]::ReadAllText($vf)).Trim() }; return $null }   # (a test's fake app)
  $v = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
  if ($v -match '^\d+\.\d+\.\d+\.\d+$') { $v = $v -replace '\.\d+$', '' }
  if (-not $v -or $v -eq '0.0.0') { return $null }
  return $v
}
function App-Procs($exe) { @(Get-Process -Name 'Overnight' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -ieq $exe }) + @(Folder-Procs (Split-Path $exe) | ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue } | Where-Object { $_.Name -ne 'Overnight' }) }
# ---- the release files: from github.com, or in a test from a folder (OVERNIGHT_TEST_RELEASE_BASE) ----
$TestBase = if ($env:OVERNIGHT_TEST_RELEASE_BASE) { [IO.Path]::GetFullPath($env:OVERNIGHT_TEST_RELEASE_BASE) } else { $null }
function Rel-Url($tag, $name) { if ($tag -eq 'latest') { "https://github.com/$Owner/$Repo/releases/latest/download/$name" } else { "https://github.com/$Owner/$Repo/releases/download/$tag/$name" } }
function Rel-Text($tag, $name) {
  if ($TestBase) { $f = Join-Path $TestBase $name; if (-not (Test-Path -LiteralPath $f)) { throw "404: $name" }; return [IO.File]::ReadAllText($f) }
  return (Web-Get (Rel-Url $tag $name))
}
function Rel-File($tag, $name, $out) {
  if ($TestBase) { $f = Join-Path $TestBase $name; if (-not (Test-Path -LiteralPath $f)) { throw "404: $name" }; Copy-Item -LiteralPath $f -Destination $out -Force; return }
  Web-File (Rel-Url $tag $name) $out
}

# ---- Overnight's own files: an install against the list of its version's files (16 Nov 2026) ----
function Manifest-For($dir, $ver) {
  # its own list (0.5.1 and newer), else the one published next to that version's installer (0.5.0); $null = none
  $own = Join-Path $dir 'resources\install-manifest.json'
  if (Test-Path -LiteralPath $own) { return $own }
  return (Release-List $ver)
}
function Release-List($ver) {
  # install-manifest-<version>.json from that version's release page (the app's scripts/release.mjs publishes it)
  if (-not $ver) { return $null }
  $f = Join-Path $Dl "install-manifest-$ver.json"
  if ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 100) { return $f }   # (fetched already in this run)
  try { Rel-File "v$ver" "install-manifest-$ver.json" $f; if ((Get-Item -LiteralPath $f).Length -gt 100) { return $f } } catch { }
  return $null
}
function Check-Install($dir, $ver) {
  # @{ ok; total; missing; wrong; first } (every listed file there with its size), $null when there is no list.
  # \\?\ paths: no 260-character limit (Crayon's Chrome sits near it); Python's bytecode and caches are not counted
  $man = Manifest-For $dir $ver
  if (-not $man) { return $null }
  $r = @{ ok = $true; total = 0; missing = 0; wrong = 0; first = New-Object System.Collections.ArrayList }
  $res = Long-Path (Join-Path $dir 'resources')
  $have = New-Object 'System.Collections.Generic.Dictionary[string,long]' ([StringComparer]::OrdinalIgnoreCase)
  if ([IO.Directory]::Exists($res)) {
    $cut = $res.Length + 1
    foreach ($f in ([IO.DirectoryInfo]::new($res)).EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) { $have[$f.FullName.Substring($cut).Replace('\', '/')] = $f.Length }
  }
  $rx = [regex]'^\["((?:[^"\\]|\\.)*)",(-?\d+|null)\],?$'
  $first = $true
  foreach ($l in [IO.File]::ReadAllLines($man)) {   # (all at once: the file is closed again at once)
    if ($first) {
      $first = $false
      if ($ver -and $l -match '"version":"([^"]+)"' -and $Matches[1] -ne $ver) { $r.ok = $false; [void]$r.first.Add("its list of files is of version $($Matches[1])"); return $r }
      continue
    }
    $m = $rx.Match($l)
    if (-not $m.Success) { continue }
    $rel = $m.Groups[1].Value
    if ($rel.Contains('\')) { $rel = [regex]::Unescape($rel) }
    if ($rel -match '(^|/)__pycache__/|\.pyc$|(^|/)node_modules/\.cache/') { continue }
    $r.total++
    $size = 0L
    if (-not $have.TryGetValue($rel, [ref]$size)) { $r.missing++; if ($r.first.Count -lt 3) { [void]$r.first.Add($rel) } }
    elseif ($m.Groups[2].Value -ne 'null' -and [long]$m.Groups[2].Value -ne $size) { $r.wrong++; if ($r.first.Count -lt 3) { [void]$r.first.Add("$rel (size)") } }
  }
  if ($r.missing -or $r.wrong -or $r.total -lt 1) { $r.ok = $false }
  return $r
}
function Check-Line($c) {
  if (-not $c) { return 'no list of its files to check against' }
  $p = @()
  if ($c.missing) { $p += "$($c.missing) of $($c.total) files missing" }
  if ($c.wrong) { $p += "$($c.wrong) of $($c.total) with the wrong size" }
  if (-not $p.Count) { $p += 'not complete' }
  return (($p -join ', ') + $(if ($c.first.Count) { ': ' + ($c.first -join ', ') } else { '' }))
}
function Free-GB($p) {
  if ($env:OVERNIGHT_TEST_FREE_GB -and $TestBase) { return [double]$env:OVERNIGHT_TEST_FREE_GB }
  try { return [math]::Round((New-Object IO.DriveInfo ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($p)))).AvailableFreeSpace / 1GB, 1) } catch { return $null }
}
function Check-Space($appDir, $unpackedGB) {
  # %TEMP%: the download and the installer's own unpacked copy; the install folder's drive: the new files (the version
  # there is moved aside on the same drive and deleted only after); half a GB more on each
  $setupGB = 0.8
  $t = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Dl)).ToUpper(); $i = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($appDir)).ToUpper()
  $need = @{}
  $need[$t] = 2 * $setupGB + $unpackedGB
  if ($need.ContainsKey($i)) { $need[$i] += $unpackedGB } else { $need[$i] = $unpackedGB }
  foreach ($d in @($need.Keys)) {
    $want = [math]::Round($need[$d] + 0.5, 1); $free = Free-GB $d
    if ($null -ne $free -and $free -lt $want) {
      Stop-Install "not enough free disk space to install Overnight: $($d.TrimEnd('\')) has $free GB free and the install needs about $want GB while it runs. Free $([math]::Round($want - $free + 0.1, 1)) GB or more (empty the Recycle Bin, move old videos or downloads to another drive), then run this installer again. Nothing was changed."
    }
    Ok "$($d.TrimEnd('\')) has $free GB free (the install needs about $want GB while it runs)"
  }
}
function Remove-AppFolder($dir) {
  # the program folder only: Overnight's data (%APPDATA%\Overnight, or the data folder it was moved to) and the videos
  # (Documents\Overnight) are elsewhere and stay. A folder that also holds other files keeps them: only resources goes
  if (-not (Test-Path -LiteralPath $dir)) { return }
  if (App-Only $dir) { Remove-Tree $dir } else { Remove-Tree (Join-Path $dir 'resources') }
}

function Latest-Release {
  # the release's own update file: version, installer file name, sha512 (no GitHub API rate limit)
  try { $yml = Rel-Text 'latest' 'latest.yml' } catch { return $null }
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
# A shell started by an app package (the Claude desktop app's own shell on Windows, seen 6 Nov 2026) can have its
# AppData writes redirected into that package's private copy (%LOCALAPPDATA%\Packages\<app>\LocalCache) without having
# a package identity of its own, so GetCurrentPackageFullName can't tell. A probe file can: written into %APPDATA%,
# does it show up in a package's LocalCache? Then Overnight, its data and its Start menu entry would be invisible to
# the member. (The probe is deleted at once.)
$redirect = $null
try {
  $probe = 'overnight-setup-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt'
  $pf = Join-Path $env:APPDATA $probe
  [IO.File]::WriteAllText($pf, 'probe')
  try {
    foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -ErrorAction SilentlyContinue)) {
      if (Test-Path -LiteralPath (Join-Path $d.FullName "LocalCache\Roaming\$probe")) { $redirect = $d.Name; break }
    }
  } finally { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue }
} catch { Note "could not check where AppData writes go ($($_.Exception.Message))" }
if ($redirect -and $TestBase) { Note "(test: AppData is redirected into $redirect; a test writes only into its own folders)"; $redirect = $null }
if ($redirect) {
  Stop-Install "this PowerShell's AppData is redirected into the app package $redirect, so what it installs would only be visible inside that app. Run it from a terminal of your own: open PowerShell (Start menu, type PowerShell, press Enter) and paste: $OneLine"
}
Ok 'AppData is the real one (not an app package''s private copy)'
$free = $null; try { $free = [math]::Round((Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free / 1GB, 1) } catch { }
if ($null -ne $free) { if ($free -lt 10) { Warn "only $free GB free on $env:SystemDrive. Overnight and its tools need about 6 GB, its videos more." } else { Ok "$free GB free on $env:SystemDrive" } }
$sac = $null
try { $sac = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState' -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState } catch { }
# Smart App Control lets only signed programs, or ones Microsoft already knows, start. Overnight is not code-signed yet,
# so with it On Windows can block Overnight's installer and the app itself, and the Python packages it uses (WinError
# 4551). Nothing in this script can get around it without a signature: the member decides
$SacHow = 'Turning Smart App Control off is your decision: Windows Security > App & browser control > Smart App Control > Off (on most Windows 11 versions it can only be turned on again by resetting Windows). Then run this installer again.'
if ($sac -eq 1) { Warn "Smart App Control is On. It may block Overnight (not code-signed yet) and the Python packages it uses (transcription, WinError 4551). $SacHow" }
elseif ($sac -eq 2) { Note 'Smart App Control is in evaluation mode: if Windows turns it On later, it may block Overnight (not code-signed yet).' }

if ($TestBase) { Warn 'Test (OVERNIGHT_TEST_RELEASE_BASE): only the Overnight step runs, from a folder of fake release files.' }
if (-not $TestBase) {
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
# a per-user Git that is not on the PATH: Overnight only looks for git on the PATH and in Program Files
if (-not $DryRun -and $g -and -not (Find-Cmd 'git') -and $g -like "$env:LOCALAPPDATA\Programs\Git\*") { Add-UserPath (Split-Path $g); Note "added $(Split-Path $g) to your PATH" }
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

}   # (not in a test: the tools)

# ---- Overnight ----
Step 'Overnight'
$AppDir = Find-AppDir
if (-not $DryRun) { Recover-Aside $AppDir }
$AppExe = Join-Path $AppDir 'Overnight.exe'
$current = App-Version $AppExe
$latest = Latest-Release
if (-not $latest) {
  if ($current) { Problem "could not reach https://github.com/$Owner/$Repo/releases, so Overnight $current was not checked for an update." }
  else { Stop-Install "could not reach https://github.com/$Owner/$Repo/releases (no internet, or a firewall, proxy or VPN blocks github.com). Nothing of Overnight was changed: run this installer again." }
}
# an install with files missing (an update that did not finish, files an antivirus took): installed again, also when it is
# the newest version (projects, settings and the Skool login stay)
$Broken = $null
if ($current) {
  $chk = Check-Install $AppDir $current
  if ($chk -and -not $chk.ok) {
    $Broken = Check-Line $chk
    Warn "Overnight $current is missing files ($Broken): it is installed again. Your videos, settings and Skool login stay."
    if (-not $latest) { Problem "Overnight $current is missing files ($Broken) and https://github.com/$Owner/$Repo/releases could not be reached to install it again. Run this installer again when the internet works." }
    $Reinstall = $true
  } elseif ($chk) { Ok "Overnight $current has all $($chk.total) of its files" }
  else { Note "Overnight $current has no list of its files to check against (it is checked after an install of a newer version)" }
}
if ($Broken -and -not $latest) { }   # (said above: no release to install it from)
elseif ($current -and (-not $latest -or ((Ver $current) -ge (Ver $latest.version) -and -not $Reinstall))) { Ok "Overnight $current is installed and up to date ($AppExe)" }
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
    # room first, for the whole install (the size of the new files from the version's list, when it has one)
    $unpackedGB = 2.7
    $relList = Release-List $target
    if ($relList) { try { $sr = New-Object IO.StreamReader($relList); try { $h0 = $sr.ReadLine() } finally { $sr.Dispose() }; if ($h0 -match '"bytes":(\d+)') { $unpackedGB = [math]::Round([double]$Matches[1] / 1GB + 0.2, 1) } } catch { } }
    Check-Space $AppDir $unpackedGB
    $setup = Join-Path $Dl $latest.file
    Note "Downloading Overnight $target (about 750 MB) ..."
    try { Rel-File "v$target" $latest.file $setup }
    catch {
      try { Rel-File 'latest' 'Overnight-Setup.exe' $setup }
      catch { Stop-Install "the download of Overnight $target failed ($($_.Exception.Message)). Nothing was changed: check the internet connection and run this installer again." }
    }
    if ($latest.sha512) {
      $h = [Security.Cryptography.SHA512]::Create(); $s = [IO.File]::OpenRead($setup)
      try { $got = [Convert]::ToBase64String($h.ComputeHash($s)) } finally { $s.Dispose() }
      if ($got -ne $latest.sha512) { Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue; Stop-Install "the download of Overnight $target was damaged on the way (it does not match the release), so it was not run. Run this installer again; if it shows again, an antivirus's web scanning or a proxy changes downloads." }
      Ok 'download checked against the release (sha512)'
    }
    # SHA-256 against the release's SHA256SUMS.txt (what the release page lists): an installer that does not match never runs
    $sums = $null; try { $sums = Rel-Text "v$target" 'SHA256SUMS.txt' } catch { }
    $want256 = $null
    if ($sums) { foreach ($l in ($sums -split "`n")) { if ($l -match '^([0-9A-Fa-f]{64})\s+\*?(\S+)\s*$' -and $Matches[2] -eq $latest.file) { $want256 = $Matches[1].ToUpper() } } }
    if (-not $want256) { Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue; Stop-Install "the release $target has no SHA-256 for $($latest.file) (SHA256SUMS.txt could not be read), so the download was not run. Nothing was changed: run this installer again in a few minutes." }
    $got256 = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToUpper()
    if ($got256 -ne $want256) { Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue; Stop-Install "the download of Overnight $target does not match the release's SHA-256 (SHA256SUMS.txt), so it was not run. Nothing was changed. Run this installer again; if it shows again, an antivirus's web scanning or a proxy changes downloads." }
    Ok "download checked against the release (SHA-256 $got256, as in SHA256SUMS.txt)"
    # OVERNIGHT_INSTALL_DIR: the member's own place (another drive). The app goes to <dir>\app; on a first install the
    # data (tools, packs) goes to <dir>\data and new videos to <dir>\videos. /D= must be the last argument, unquoted.
    # Without it the installer keeps the folder Overnight is already in (its registry entry), so an update never moves it
    $iargs = @('/S')
    if ($InstallRoot) {
      try { New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null; $t = Join-Path $InstallRoot '.overnight-write-test'; Set-Content -LiteralPath $t -Value ''; Remove-Item -LiteralPath $t -Force }
      catch { Stop-Install "Overnight can't write in $InstallRoot ($($_.Exception.Message)). Pick another folder for OVERNIGHT_INSTALL_DIR, or leave it out." }
      $iargs = @('/S', ('/D=' + (Join-Path $InstallRoot 'app')))
      Note "Installing into $InstallRoot\app (per user, no admin rights) ..."
    } else { Note 'Installing (per user, no admin rights) ...' }
    # the installed version moves aside first (Move-OldApp). When the folder holds other files too, the old route: its
    # style packs go by a \\?\ path (Crayon's Chrome there is the path that got too long), then its own uninstaller
    $oldDir = $AppDir; $aside = $null
    if ($current -and (Test-Path -LiteralPath $AppExe)) { $aside = Move-OldApp $AppDir }
    $packs = Join-Path $AppDir 'resources\stylepacks'
    if (-not $aside -and $current -and (Test-Path -LiteralPath $AppExe) -and (Test-Path -LiteralPath $packs)) {
      Note "removing the old version's style packs first ($packs) ..."
      Remove-Tree $packs
      if (Test-Path -LiteralPath $packs) { Warn "$packs could not be removed completely; if the install stops with code 2, restart the computer and run this installer again." }
    }
    try { $code = Run-Installer $setup $iargs 15 }
    catch {
      # (an installer still running after 15 minutes keeps its folder: the next run of this script puts the old one back)
      $back = if ("$($_.Exception.Message)" -notmatch 'did not finish in') { Put-Back $aside $oldDir } else { $false }
      $kept = if ($back) { ' The version you had is back.' } else { '' }
      if ($Sac -eq 1 -or "$($_.Exception.Message)" -match 'Application Control|Smart App|4551|blocked') {
        Stop-Install "Windows did not let the Overnight installer start ($($_.Exception.Message)). Smart App Control is On, and it blocks Overnight because Overnight is not code-signed yet.$kept $SacHow"
      }
      Stop-Install "the Overnight installer could not run ($($_.Exception.Message)).$kept Run this installer again; if it shows again, restart the computer first."
    }
    if ($InstallRoot -and $code -eq 0) {
      $home0 = Join-Path $env:APPDATA 'Overnight'; $ptr = Join-Path $home0 'data-location.json'
      if ((Test-Path -LiteralPath (Join-Path $home0 'settings.json')) -or (Test-Path -LiteralPath $ptr)) {
        [void]$NextSteps.Add("Overnight's tools and data are still where they were. To move them too: Settings > General > Data folder > Move.")
      } else {
        $data = Join-Path $InstallRoot 'data'; $vids = Join-Path $InstallRoot 'videos'
        New-Item -ItemType Directory -Force -Path $home0, $data, $vids | Out-Null
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($ptr, (@{ dir = $data } | ConvertTo-Json), $utf8)
        [IO.File]::WriteAllText((Join-Path $data 'settings.json'), (@{ workspace = $vids } | ConvertTo-Json), $utf8)
        Ok "tools and data will live in $data, videos in $vids"
      }
    }
    $AppDir = Find-AppDir; $AppExe = Join-Path $AppDir 'Overnight.exe'
    $now = App-Version $AppExe
    if ($code -ne 0 -or -not $now) {
      Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue
      $kept = if (Put-Back $aside $oldDir) { ' The version you had is back and still works.' } else { '' }
      if ($code -eq 2) { Stop-Install "the Overnight installer stopped (code 2): Windows did not let it replace Overnight's files, a program is using one of them, or the disk was too full.$kept Free some disk space, restart the computer, then run this installer again." }
      Stop-Install "the Overnight installer did not finish (code $code).$kept An antivirus may have blocked it: check its quarantine, then run this installer again."
    }
    # every file of the new version there (its list): an incomplete install is removed (the program folder only) and
    # installed once more
    $chk = Check-Install $AppDir $now
    if ($chk -and -not $chk.ok) {
      Warn "the install is missing files ($(Check-Line $chk)): removing Overnight's program folder and installing it once more (your videos, settings and Skool login are elsewhere and stay)"
      Remove-AppFolder $AppDir
      try { $code = Run-Installer $setup $iargs 15 } catch { $code = -1 }
      $now = App-Version $AppExe
      $chk = Check-Install $AppDir $now
    }
    Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue
    if ($chk -and -not $chk.ok) {
      $line = Check-Line $chk
      $kept = ''
      if ($aside -and $current -and (Ver $current) -lt (Ver $target) -and -not $Broken) { Remove-AppFolder $AppDir; if (Put-Back $aside $oldDir) { $kept = " The version you had ($current) is back."; $aside = $null } }
      Stop-Install "Overnight $target is still missing files after installing it twice ($line).$kept Free some disk space (the install needs about $unpackedGB GB plus room for the download), restart the computer, then run this installer again. If an antivirus took files, allow Overnight's folder in it first."
    }
    if ($chk) { Ok "all $($chk.total) of Overnight's files are there" }
    elseif ($code -eq 0) { Note "no list of Overnight $now's files to check against: not checked" }
    if ($aside) {
      Remove-Item -LiteralPath (Join-Path $aside '.ovn-moved') -Force -ErrorAction SilentlyContinue
      Remove-Tree $aside
      if (Test-Path -LiteralPath $aside) { Note "the old version's folder $aside could not be removed completely; the next update removes it" } else { Note 'the old version''s files are removed' }
    }
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
if (-not $DryRun) {
  Put '' White
  Put 'Next:' White
  foreach ($t in $NextSteps) { Put "  - $t" White }
}
Put '' White
if ($Problems.Count) {
  Put "Finished, with $($Problems.Count) problem(s) left:" Yellow
  foreach ($t in $Problems) { Put "  - $t" Yellow }
  Put 'Run the same command again any time to update or repair.' White
} elseif ($DryRun) { Put 'Test mode finished: nothing was changed.' White }
else { Put 'All set. Run the same command again any time to update or repair.' White }
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
