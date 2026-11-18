# Overnight setup for Windows (install.ps1)
#
# Puts Overnight and the tools it needs on a 64-bit Windows 10 (version 1809 or newer) or Windows 11 PC, for the
# signed-in user, without administrator rights. The one exception is the Microsoft Visual C++ runtime, which is
# per machine: Windows asks for permission once, and the member clicks Yes.
#
# Run it from the web (it never closes your window):
#   irm https://raw.githubusercontent.com/nnovoselski04/overnight-releases/main/install.ps1 | iex
# or as a file:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#
# Settings are environment variables. A setting is on when it holds 1 (test mode: any non-empty value).
#   OVERNIGHT_SETUP_DRY          test mode: look and report, change nothing
#   OVERNIGHT_NO_OPEN            do not start Overnight at the end
#   OVERNIGHT_CLOSE_APP          you agree that an open Overnight may be closed for the update
#   OVERNIGHT_REINSTALL          put the newest Overnight on again even when it is up to date (repair)
#   OVERNIGHT_INSTALL_DIR        another root folder, for example E:\Overnight (the app goes into <root>\app)
#   OVERNIGHT_SETUP_NO_WINGET    tests only: act as if winget were missing
#   OVERNIGHT_TEST_RELEASE_BASE  tests only: a folder holding a fake release; only the Overnight step runs, its
#                                fake-installer.ps1 stands in for the installer
#   OVERNIGHT_TEST_APPDIR        tests only, with the above: the install folder (version read from version.txt)
#   OVERNIGHT_TEST_FREE_GB       tests only, with the above: the free space of every drive, in GB
#
# Exit codes: 0 everything is in place; 3 finished, with problems listed at the end; 1 stopped (the reason is on
# the last lines). Test mode exits 0 unless it stops.
#
# Before anything is fetched it checks the room on the drives; the installer must match both the SHA-512 in
# latest.yml and the SHA-256 in the version's SHA256SUMS.txt; afterwards every install is checked against the
# version's list of files, and installed once more if files are missing.
#
# What it writes, and nothing more:
#   - %TEMP%\overnight-setup\: its log (install.log), the files it fetches (removed after use: installers, the
#     version's file list install-manifest-<version>.json), a small Python check
#   - a probe file in %APPDATA%, removed at once (it shows whether AppData is redirected into an app package)
#   - the tools it adds when they are missing or unusable: git, ffmpeg, Python 3.12, the Visual C++ runtime,
#     Claude Code and Overnight itself
#   - during an update: the old version is moved aside to "<install folder>.ovn-old" with a marker file
#     ".ovn-moved" (the folder's path), and removed once the new version is complete or put back if it is not.
#     A folder holding anything besides Overnight's own files is never moved.
#   - your user PATH: the folders of those tools, each added once
#   - only with OVERNIGHT_INSTALL_DIR on a first install (no Overnight settings and no data pointer yet): the folders
#     <root>\app, <root>\data and <root>\videos, the data pointer %APPDATA%\Overnight\data-location.json and the
#     settings file <root>\data\settings.json (it holds only the folder for new videos). Neither file is ever
#     overwritten.
# It never touches your videos, projects, settings or sign-ins, never removes or changes another program, never
# closes a program other than Overnight (and Overnight only with OVERNIGHT_CLOSE_APP=1), never changes antivirus or
# Smart App Control, and never asks for or prints a password, key or token.

& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ------------------------------------------------------------------ state and output

function New-OvnState {
    $temp = $env:TEMP
    if (-not $temp) { $temp = [System.IO.Path]::GetTempPath() }
    $folder = Join-Path $temp 'overnight-setup'
    return @{
        Folder      = $folder
        Log         = Join-Path $folder 'install.log'
        Utf8        = New-Object System.Text.UTF8Encoding $false
        Dry         = $false
        NoOpen      = $false
        CloseApp    = $false
        Reinstall   = $false
        NoWinget    = $false
        InstallDir  = ''
        TestBase    = $null
        TestAppDir  = $null
        TestFreeGB  = $null
        ListTried   = @{}
        Winget      = $null
        Step        = 0
        Steps       = 11
        Problems    = New-Object System.Collections.ArrayList
        Later       = New-Object System.Collections.ArrayList
        Downloads   = New-Object System.Collections.ArrayList
        Stopped     = $false
        StopReason  = ''
        StopFix     = ''
        StopMarker  = New-Object System.Object
        WebError    = ''
        App         = $null
        VideosDir   = $null
        Repo        = 'https://github.com/nnovoselski04/overnight-releases'
        ReleaseBase = 'https://github.com/nnovoselski04/overnight-releases/releases/'
        OneLiner    = 'irm https://raw.githubusercontent.com/nnovoselski04/overnight-releases/main/install.ps1 | iex'
        Community   = 'https://www.skool.com/overnight-ai-video-automation-5588'
    }
}

function Write-OvnLog([string]$Text) {
    try {
        if (-not (Test-Path -LiteralPath $Kit.Folder)) { $null = New-Item -ItemType Directory -Path $Kit.Folder -Force }
        [System.IO.File]::AppendAllText($Kit.Log, $Text + "`r`n", $Kit.Utf8)
    } catch { }
}

function Write-OvnOut([string]$Text, [string]$Color) {
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
    Write-OvnLog $Text
}

function Write-OvnStep([string]$Title) {
    $Kit.Step++
    Write-OvnOut ''
    Write-OvnOut ('== Step {0} of {1}: {2}' -f $Kit.Step, $Kit.Steps, $Title) 'Cyan'
}

function Write-OvnOk([string]$Text)   { Write-OvnOut ('   [ok]   ' + $Text) 'Green' }
function Write-OvnNote([string]$Text) { Write-OvnOut ('   [..]   ' + $Text) }
function Write-OvnWarn([string]$Text) { Write-OvnOut ('   [warn] ' + $Text) 'Yellow' }

# The only place that prints the words the CI looks for on a second run. Call it only right before a real
# download or a real install starts.
function Write-OvnBegin {
    param([ValidateSet('Install', 'Download')][string]$Kind, [string]$What)
    if ($Kind -eq 'Install') { $word = 'Installing ' } else { $word = 'Downloading ' }
    Write-OvnOut ('   [..]   ' + $word + $What)
}

function Add-OvnProblem([string]$Text, [string]$Fix) {
    if ($Kit.Dry) {
        [void]$Kit.Later.Add($Text)
        Write-OvnOut ('   [note] A real run would report this problem: ' + $Text) 'Yellow'
        return
    }
    [void]$Kit.Problems.Add(@{ Text = $Text; Fix = $Fix })
    Write-OvnOut ('   [problem] ' + $Text) 'Red'
    if ($Fix) { Write-OvnOut ('             What to do: ' + $Fix) 'Red' }
}

# Ends the run on purpose. The main function catches it, prints the reason last and returns 1.
function Stop-OvnSetup([string]$Reason, [string]$Fix) {
    $Kit.Stopped = $true
    $Kit.StopReason = $Reason
    $Kit.StopFix = $Fix
    throw $Kit.StopMarker
}

# The three message names the move-aside helpers use (ci\test-move-aside.ps1 supplies its own).
function Note([string]$Text) { Write-OvnNote $Text }
function Warn([string]$Text) { Write-OvnWarn $Text }
function Stop-Install([string]$Text) { Stop-OvnSetup $Text '' }

# ------------------------------------------------------------------ small pure helpers (unit-tested)

function Test-OvnOn([string]$Value) { return ("$Value".Trim() -eq '1') }

function Test-OvnNonEmpty([string]$Value) { return (-not [string]::IsNullOrEmpty($Value)) }

function ConvertTo-OvnVersion([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    if ($t -match '^[vV]') { $t = $t.Substring(1) }
    $t = ($t -split '[-+ ]')[0]
    $parts = @($t.Split('.'))
    if ($parts.Count -eq 4) { $parts = @($parts[0], $parts[1], $parts[2]) }
    if ($parts.Count -lt 1 -or $parts.Count -gt 3) { return $null }
    $nums = @()
    foreach ($p in $parts) {
        $n = 0
        if (-not [int]::TryParse($p, [ref]$n) -or $n -lt 0) { return $null }
        $nums += $n
    }
    while ($nums.Count -lt 3) { $nums += 0 }
    return (New-Object System.Version $nums[0], $nums[1], $nums[2])
}

function Format-OvnVersion([string]$Text) {
    $v = ConvertTo-OvnVersion $Text
    if ($v) { return ('{0}.{1}.{2}' -f $v.Major, $v.Minor, $v.Build) }
    return "$Text"
}

# -1 when A is older than B, 0 when equal, 1 when newer. Something unreadable counts as oldest.
function Compare-OvnVersion([string]$A, [string]$B) {
    $va = ConvertTo-OvnVersion $A
    $vb = ConvertTo-OvnVersion $B
    if (-not $va -and -not $vb) { return 0 }
    if (-not $va) { return -1 }
    if (-not $vb) { return 1 }
    return [Math]::Sign($va.CompareTo($vb))
}

function Get-OvnUnquoted([string]$Value) {
    $v = "$Value".Trim()
    if ($v.Length -ge 2) {
        $first = $v.Substring(0, 1); $last = $v.Substring($v.Length - 1, 1)
        if (($first -eq "'" -and $last -eq "'") -or ($first -eq '"' -and $last -eq '"')) { return $v.Substring(1, $v.Length - 2) }
    }
    return $v
}

# Reads electron-builder's latest.yml: version, installer file name, its SHA-512 (base64) and size.
function Read-OvnFeed([string]$Text) {
    $top = @{}
    $files = New-Object System.Collections.ArrayList
    $current = $null
    foreach ($raw in ("$Text" -split "`r?`n")) {
        $line = $raw.TrimEnd()
        if (-not $line.Trim() -or $line.TrimStart().StartsWith('#')) { continue }
        if ($line -match '^([A-Za-z][A-Za-z0-9_]*):\s*(.*)$') {
            $top[$Matches[1]] = Get-OvnUnquoted $Matches[2]
            $current = $null
        } elseif ($line -match '^\s+-\s+url:\s*(.+)$') {
            $current = @{ Url = (Get-OvnUnquoted $Matches[1]); Sha512 = $null; Size = $null }
            [void]$files.Add($current)
        } elseif ($current -and $line -match '^\s+(sha512|size):\s*(.+)$') {
            if ($Matches[1] -eq 'sha512') { $current.Sha512 = Get-OvnUnquoted $Matches[2] } else { $current.Size = Get-OvnUnquoted $Matches[2] }
        }
    }
    $feed = @{ Version = $null; Installer = $null; Sha512 = $null; Size = $null }
    if ($top['version'] -and (ConvertTo-OvnVersion $top['version'])) { $feed.Version = Format-OvnVersion $top['version'] }
    if ($top['path'] -and $top['path'] -match '\.exe$') { $feed.Installer = $top['path'] }
    if (-not $feed.Installer) {
        $exe = @($files | Where-Object { $_.Url -match '\.exe$' } | Select-Object -First 1)
        if ($exe.Count) { $feed.Installer = $exe[0].Url }
    }
    $entry = @($files | Where-Object { $_.Url -eq $feed.Installer } | Select-Object -First 1)
    if ($entry.Count -and $entry[0].Sha512) { $feed.Sha512 = $entry[0].Sha512 } elseif ($top['sha512']) { $feed.Sha512 = $top['sha512'] }
    if ($entry.Count -and $entry[0].Size) { $n = 0L; if ([long]::TryParse($entry[0].Size, [ref]$n)) { $feed.Size = $n } }
    if ($feed.Installer -and $feed.Installer -notmatch '^[A-Za-z0-9._-]+$') { $feed.Installer = $null }
    return $feed
}

# Reads SHA256SUMS.txt into a table of file name -> lower-case hex. Returns $null when it holds no valid line.
function Read-OvnSums([string]$Text) {
    $map = @{}
    foreach ($line in ("$Text" -split "`r?`n")) {
        if ($line -match '^\s*([0-9A-Fa-f]{64})\s+\*?(.+?)\s*$') { $map[$Matches[2]] = $Matches[1].ToLowerInvariant() }
    }
    if ($map.Count) { return $map }
    return $null
}

function ConvertTo-OvnBase64FromHex([string]$Hex) {
    $bytes = New-Object 'byte[]' ([int]($Hex.Length / 2))
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    return [Convert]::ToBase64String($bytes)
}

function ConvertFrom-OvnHexUtf8([string]$Hex) {
    if (-not $Hex -or ($Hex.Length % 2) -ne 0 -or $Hex -notmatch '^[0-9A-Fa-f]+$') { return $null }
    $bytes = New-Object 'byte[]' ([int]($Hex.Length / 2))
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

# Decides whether a downloaded Overnight installer may run: the SHA-512 in latest.yml when it has one, and always
# the SHA-256 line for the installer's name in the version's SHA256SUMS.txt.
function Get-OvnHashVerdict {
    param([string]$Actual512, [string]$Actual256, [string]$Feed512, $Sums, [string]$Name)
    if ($Feed512 -and ($Actual512 -cne $Feed512)) { return @{ Ok = $false; Why = 'sha512' } }
    if (-not $Sums -or -not $Sums.ContainsKey($Name)) { return @{ Ok = $false; Why = 'no-sums' } }
    if ("$Actual256".ToLowerInvariant() -ne $Sums[$Name]) { return @{ Ok = $false; Why = 'sha256' } }
    return @{ Ok = $true; Why = '' }
}

function Get-OvnPathKey([string]$Dir) {
    return [Environment]::ExpandEnvironmentVariables("$Dir".Trim().Trim('"')).TrimEnd('\').ToLowerInvariant()
}

function Test-OvnPathListHas([string]$List, [string]$Dir) {
    $want = Get-OvnPathKey $Dir
    if (-not $want) { return $false }
    foreach ($item in ("$List" -split ';')) {
        if ($item.Trim() -and (Get-OvnPathKey $item) -eq $want) { return $true }
    }
    return $false
}

# Returns the new PATH text with Dir added at the end, or $null when Dir is already there.
function Join-OvnPathList([string]$Current, [string]$Dir) {
    if (Test-OvnPathListHas $Current $Dir) { return $null }
    if ([string]::IsNullOrEmpty($Current) -or -not $Current.Trim(';').Trim()) { return $Dir }
    return ($Current.TrimEnd(';') + ';' + $Dir)
}

# Quotes arguments the way Windows programs split their command line.
function Join-OvnArguments([string[]]$List) {
    $out = New-Object System.Collections.ArrayList
    foreach ($a in @($List)) {
        if ($null -eq $a) { continue }
        if ($a -eq '') { [void]$out.Add('""'); continue }
        if ($a -notmatch '[\s"]') { [void]$out.Add($a); continue }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        $slashes = 0
        foreach ($ch in $a.ToCharArray()) {
            if ($ch -eq [char]'\') { $slashes++; continue }
            if ($ch -eq [char]'"') { [void]$sb.Append(('\' * ($slashes * 2 + 1)) + '"'); $slashes = 0; continue }
            if ($slashes) { [void]$sb.Append('\' * $slashes); $slashes = 0 }
            [void]$sb.Append($ch)
        }
        [void]$sb.Append('\' * ($slashes * 2))
        [void]$sb.Append('"')
        [void]$out.Add($sb.ToString())
    }
    return ($out -join ' ')
}

# Turns the OVERNIGHT_INSTALL_DIR value into a full path. Surrounding quotes and spaces are fine.
function Resolve-OvnRoot([string]$Raw) {
    $v = "$Raw".Trim().Trim([char[]]@('"', "'")).Trim()
    if (-not $v) { return $null }
    if ($v -match '^[A-Za-z]:$') { $v += '\' }
    if ($v -match '^([A-Za-z]:\\|\\\\)') { $full = [System.IO.Path]::GetFullPath($v) }
    else { $full = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($v)) }
    if ($full -notmatch '^([A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)') { throw "not a folder on a drive: $v" }
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\') }
    return $full
}

# Where the app and its data go, given OVERNIGHT_INSTALL_DIR and what is already on the PC.
function Get-OvnDrivePlan {
    param([string]$Root, [bool]$Installed, [bool]$Reinstall, [bool]$HasSettings, [bool]$HasPointer)
    $plan = @{ UseRoot = $false; Ignored = $false; AppDir = $null; DataDir = $null; VideosDir = $null; FirstInstall = $false }
    if (-not $Root) { return $plan }
    if ($Installed -and -not $Reinstall) { $plan.Ignored = $true; return $plan }
    $plan.UseRoot = $true
    # (Path.Combine, not Join-Path: Join-Path fails on a drive that is not there.)
    $plan.AppDir = [System.IO.Path]::Combine($Root, 'app')
    $plan.DataDir = [System.IO.Path]::Combine($Root, 'data')
    $plan.VideosDir = [System.IO.Path]::Combine($Root, 'videos')
    $plan.FirstInstall = (-not $HasSettings) -and (-not $HasPointer)
    return $plan
}

function ConvertTo-OvnJsonText([string]$Text) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in "$Text".ToCharArray()) {
        $n = [int]$ch
        if ($ch -eq [char]'"') { [void]$sb.Append('\"') }
        elseif ($ch -eq [char]'\') { [void]$sb.Append('\\') }
        elseif ($n -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $n)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# The Python path in Overnight's settings, read both as {"tools":{"python":...}} and as {"tools.python":...}.
function Get-OvnSettingsPython([string]$Json) {
    if (-not $Json) { return $null }
    try { $j = $Json | ConvertFrom-Json } catch { return $null }
    if (-not $j) { return $null }
    $v = $null
    if ($j.tools -and ($j.tools | Get-Member -Name python -ErrorAction SilentlyContinue)) { $v = $j.tools.python }
    if (-not $v -and ($j | Get-Member -Name 'tools.python' -ErrorAction SilentlyContinue)) { $v = $j.'tools.python' }
    if ($v -is [string] -and $v.Trim()) { return $v.Trim() }
    return $null
}

function ConvertFrom-OvnPyProbe([string]$Line, [string]$Asked) {
    $none = @{ Ran = $false; Asked = $Asked; Exe = $Asked }
    if (-not $Line) { return $none }
    $f = $Line.Split('|')
    if ($f.Count -lt 7 -or $f[0] -ne 'pyprobe') { return $none }
    $major = 0; $minor = 0; $bits = 0
    if (-not [int]::TryParse($f[1], [ref]$major) -or -not [int]::TryParse($f[2], [ref]$minor) -or -not [int]::TryParse($f[3], [ref]$bits)) { return $none }
    $exe = ConvertFrom-OvnHexUtf8 $f[6]
    if (-not $exe) { $exe = $Asked }
    $missing = @($f[5].Split(',') | Where-Object { $_ })
    return @{ Ran = $true; Asked = $Asked; Exe = $exe; Major = $major; Minor = $minor; Bits = $bits; Conda = ($f[4] -eq '1'); Missing = $missing }
}

# $null when Overnight can use this Python, otherwise the reason it cannot.
function Get-OvnPythonVerdict($Probe) {
    if (-not $Probe -or -not $Probe.Ran) { return 'it does not start or does not answer' }
    $ver = '{0}.{1}' -f $Probe.Major, $Probe.Minor
    if ($Probe.Major -ne 3 -or $Probe.Minor -lt 10) { return "it is Python $ver, too old (Overnight needs 3.10 to 3.13)" }
    if ($Probe.Minor -gt 13) { return "it is Python $ver, too new (Overnight needs 3.10 to 3.13)" }
    if ($Probe.Bits -ne 64) { return "it is a $($Probe.Bits)-bit Python (Overnight needs 64-bit)" }
    if ($Probe.Conda) { return 'it is a conda Python (Overnight needs a plain python.org Python)' }
    if ($Probe.Missing.Count) { return ('it cannot load ' + ($Probe.Missing -join ', ')) }
    return $null
}

# The app accepts a Python whose version starts with "3.1".
function Test-OvnAppWouldAccept($Probe) {
    return ($Probe -and $Probe.Ran -and $Probe.Major -eq 3 -and ("$($Probe.Minor)" -like '1*'))
}

function Get-OvnWingetOutcome($Code) {
    if ($null -eq $Code) { return 'failed' }
    if (@(0, -1978335189, -1978335135) -contains [int]$Code) { return 'ok' }
    if ([int]$Code -eq -1978335138) { return 'intercepted' }
    return 'failed'
}

function Test-OvnLooksLikeHtml([string]$Text) {
    return ("$Text" -match '^\s*(<!doctype\s+html|<html|<head|<!--)')
}

function Get-OvnPackageFromHit([string]$HitPath) {
    # ...\Packages\<package>\LocalCache\Roaming\<probe file>
    $roaming = Split-Path -Parent $HitPath
    $cache = Split-Path -Parent $roaming
    return (Split-Path -Leaf (Split-Path -Parent $cache))
}

function Test-OvnStubPath([string]$Path) { return ("$Path" -like '*\WindowsApps\*') }

function Format-OvnCode($Code) {
    if ($null -eq $Code) { return 'none' }
    $c = [int]$Code
    if ($c -lt 0 -or $c -gt 65535) { return ('{0} (0x{1:X8})' -f $c, $c) }
    return "$c"
}

# ------------------------------------------------------------------ programs, network, files

function Invoke-OvnProgram([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSec = 60) {
    $result = @{ Started = $false; TimedOut = $false; Code = $null; Stdout = ''; Stderr = ''; Lines = @(); Error = '' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = Join-OvnArguments $ArgumentList
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    try { [void]$p.Start() } catch { $result.Error = $_.Exception.Message; return $result }
    $result.Started = $true
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        # It is left running: this script ends no program it did not install itself.
        $result.TimedOut = $true
        return $result
    }
    $result.Code = $p.ExitCode
    # A program can leave a child behind that keeps the output pipes open; read what is there, never wait on it.
    try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($outTask, $errTask), 10000) } catch { }
    if ($outTask.IsCompleted -and -not $outTask.IsFaulted) { $result.Stdout = $outTask.Result }
    if ($errTask.IsCompleted -and -not $errTask.IsFaulted) { $result.Stderr = $errTask.Result }
    $result.Lines = @(("$($result.Stdout)`n$($result.Stderr)" -split "`r?`n") | Where-Object { $_.Trim() })
    return $result
}

function Find-OvnWin32Error($Exception) {
    $e = $Exception
    while ($e) {
        if ($e -is [System.ComponentModel.Win32Exception]) { return $e.NativeErrorCode }
        $e = $e.InnerException
    }
    return $null
}

# Starts an installer through the shell (so a Windows permission box can appear) and waits for that process only.
function Start-OvnInstaller([string]$FilePath, [string]$Arguments, [int]$TimeoutMinutes, [switch]$NoShell) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = -not $NoShell
    if ($NoShell) { $psi.CreateNoWindow = $true }
    $psi.WorkingDirectory = Split-Path -Parent $FilePath
    try { $p = [System.Diagnostics.Process]::Start($psi) } catch {
        return @{ Started = $false; Declined = ((Find-OvnWin32Error $_.Exception) -eq 1223); Error = $_.Exception.Message }
    }
    if (-not $p) { return @{ Started = $false; Declined = $false; Error = 'Windows did not start it' } }
    $null = $p.Handle
    if (-not $p.WaitForExit($TimeoutMinutes * 60000)) { return @{ Started = $true; TimedOut = $true } }
    return @{ Started = $true; TimedOut = $false; Code = $p.ExitCode }
}

function Get-OvnCurl {
    $c = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $c) { return $c }
    return $null
}

function Initialize-OvnNetwork {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    try {
        $proxy = [Net.WebRequest]::DefaultWebProxy
        if ($proxy) { $proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials }
    } catch { }
}

function New-OvnWebClient {
    $wc = New-Object System.Net.WebClient
    $wc.Headers['User-Agent'] = 'overnight-setup'
    $wc.Encoding = [System.Text.Encoding]::UTF8
    if ([Net.WebRequest]::DefaultWebProxy) { $wc.Proxy = [Net.WebRequest]::DefaultWebProxy }
    return $wc
}

# Small text (a release feed, a checksum list, a release description), read into memory. $null when it fails.
function Get-OvnWebText([string]$Url) {
    $Kit.WebError = ''
    for ($i = 1; $i -le 2; $i++) {
        $wc = New-OvnWebClient
        try { return $wc.DownloadString($Url) } catch { $Kit.WebError = $_.Exception.Message } finally { $wc.Dispose() }
        Start-Sleep -Seconds 2
    }
    $curl = Get-OvnCurl
    if ($curl) {
        $r = Invoke-OvnProgram $curl @('-fsSL', '--connect-timeout', '20', '--max-time', '90', '-A', 'overnight-setup', $Url) 120
        if ($r.Started -and -not $r.TimedOut -and $r.Code -eq 0 -and $r.Stdout) { return $r.Stdout }
    }
    return $null
}

# A file, to disk, with retries: curl.exe first, then PowerShell's own web client. Returns $true when it is there.
function Save-OvnFile([string]$Url, [string]$Destination, [int]$Tries = 3) {
    $Kit.WebError = ''
    $part = $Destination + '.part'
    foreach ($f in @($part, $Destination)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    $curl = Get-OvnCurl
    for ($i = 1; $i -le $Tries; $i++) {
        if ($curl) {
            $r = Invoke-OvnProgram $curl @('-fL', '--silent', '--show-error', '--connect-timeout', '30', '--speed-limit', '2048', '--speed-time', '120', '-A', 'overnight-setup', '-o', $part, $Url) 7200
            if ($r.Started -and -not $r.TimedOut -and $r.Code -eq 0 -and (Test-Path -LiteralPath $part)) {
                Move-Item -LiteralPath $part -Destination $Destination -Force
                return $true
            }
            if ($r.TimedOut) { $Kit.WebError = 'the download took too long'; return $false }
            $Kit.WebError = (@($r.Lines) + $r.Error | Where-Object { $_ } | Select-Object -Last 1)
        }
        $wc = New-OvnWebClient
        try {
            $wc.DownloadFile($Url, $part)
            Move-Item -LiteralPath $part -Destination $Destination -Force
            return $true
        } catch { $Kit.WebError = $_.Exception.Message } finally { $wc.Dispose() }
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
        if ($i -lt $Tries) { Start-Sleep -Seconds (3 * $i) }
    }
    return $false
}

function Remove-OvnFile([string]$Path) {
    foreach ($f in @($Path, ($Path + '.part'))) {
        try { if ($f -and (Test-Path -LiteralPath $f)) { Remove-Item -LiteralPath $f -Force } } catch { }
    }
}

function Remove-OvnDownloads {
    foreach ($f in @($Kit.Downloads)) { Remove-OvnFile $f }
    Remove-OvnFile (Join-Path $Kit.Folder 'pyprobe.py')
}

function Get-OvnFileHashes([string]$Path) {
    $h512 = (Get-FileHash -LiteralPath $Path -Algorithm SHA512).Hash
    $h256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return @{ Sha512 = (ConvertTo-OvnBase64FromHex $h512); Sha256 = $h256.ToLowerInvariant() }
}

function Get-OvnSignature([string]$Path) {
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $Path
        $signer = ''
        if ($s.SignerCertificate) { $signer = $s.SignerCertificate.Subject }
        return @{ Valid = ("$($s.Status)" -eq 'Valid'); Status = "$($s.Status)"; Signer = $signer }
    } catch { return @{ Valid = $false; Status = $_.Exception.Message; Signer = '' } }
}

function Get-OvnFreeBytes([string]$Path) {
    if ($Kit.TestBase -and $null -ne $Kit.TestFreeGB) { return [double]($Kit.TestFreeGB * 1GB) }
    try { return (New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($Path))).AvailableFreeSpace } catch { return $null }
}

function Format-OvnGB($Bytes) { return ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.0} GB', ($Bytes / 1GB))) }

# ------------------------------------------------------------------ PATH

function Get-OvnRegistryPath {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    return ((@($m, $u) | Where-Object { $_ }) -join ';')
}

function Update-OvnSessionPath { $env:Path = Get-OvnRegistryPath }

function Send-OvnEnvironmentChange {
    try {
        if (-not ('OvernightSetup.EnvNotify' -as [type])) {
            Add-Type -Namespace OvernightSetup -Name EnvNotify -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@
        }
        $res = [UIntPtr]::Zero
        [void][OvernightSetup.EnvNotify]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$res)
    } catch { }
}

# Adds a folder to the user PATH once, keeping %VARIABLES% in the existing value as they are.
function Add-OvnUserPath([string]$Dir, [string]$Label) {
    if (Test-OvnPathListHas (Get-OvnRegistryPath) $Dir) { return }
    if ($Kit.Dry) { Write-OvnNote "A real run would add $Dir to your user PATH, so $Label works in new windows."; return }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if (-not $key) { $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment') }
    try {
        $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $new = Join-OvnPathList $raw $Dir
        if ($null -eq $new) { return }
        $key.SetValue('Path', $new, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally { $key.Close() }
    Send-OvnEnvironmentChange
    if (-not (Test-OvnPathListHas $env:Path $Dir)) { $env:Path = $env:Path.TrimEnd(';') + ';' + $Dir }
    Write-OvnWarn "Added $Dir to your user PATH, so $Label works in new windows. Windows already open do not see it."
}

# ------------------------------------------------------------------ finding tools

function Get-OvnCommandPaths([string]$Name) {
    return @(Get-Command $Name -CommandType Application -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source } | Where-Object { $_ })
}

# The first candidate that exists and answers its version question.
function Find-OvnTool([string[]]$Candidates, [string[]]$VersionArgs, [string]$Expect) {
    $seen = @{}
    foreach ($c in @($Candidates)) {
        if (-not $c) { continue }
        $k = $c.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        if (Test-OvnStubPath $c) { continue }
        if (-not (Test-Path -LiteralPath $c -PathType Leaf)) { continue }
        $r = Invoke-OvnProgram $c $VersionArgs 60
        if ($r.Started -and -not $r.TimedOut -and $r.Code -eq 0) {
            $hit = @($r.Lines | Where-Object { $_ -match $Expect } | Select-Object -First 1)
            if ($hit.Count) { return @{ Path = $c; Version = (($hit[0] -replace '\s+Copyright.*$', '').Trim()) } }
        }
    }
    return $null
}

function Confirm-OvnOnPath([string]$Exe, [string]$Label) {
    $dir = Split-Path -Parent $Exe
    if (-not (Test-OvnPathListHas (Get-OvnRegistryPath) $dir)) { Add-OvnUserPath $dir $Label }
}

function Get-OvnGitCandidates {
    $list = @(Get-OvnCommandPaths 'git')
    foreach ($pf in @($env:ProgramW6432, $env:ProgramFiles)) { if ($pf) { $list += (Join-Path $pf 'Git\cmd\git.exe') } }
    $list += (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')
    return $list
}

function Get-OvnFfmpegCandidates {
    $list = @(Get-OvnCommandPaths 'ffmpeg')
    $list += (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ffmpeg.exe')
    $pkgs = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $pkgs) {
        foreach ($d in @(Get-ChildItem -LiteralPath $pkgs -Directory -Filter 'Gyan.FFmpeg*' -ErrorAction SilentlyContinue)) {
            $list += @(Get-ChildItem -LiteralPath $d.FullName -Recurse -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        }
    }
    $list += (Join-Path $env:LOCALAPPDATA 'Programs\ffmpeg\bin\ffmpeg.exe')
    return $list
}

function Get-OvnClaudeCandidates {
    $list = @(Get-OvnCommandPaths 'claude')
    $list += (Join-Path $env:USERPROFILE '.local\bin\claude.exe')
    return $list
}

# ------------------------------------------------------------------ adding tools

function Install-OvnWithWinget([string]$Id, [string]$Label, [switch]$UserScope) {
    if (-not $Kit.Winget) { return 'skipped' }
    Write-OvnBegin Install "$Label with winget"
    $a = @('install', '--id', $Id, '--exact', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements')
    if ($UserScope) { $a += @('--scope', 'user') }
    $r = Invoke-OvnProgram $Kit.Winget $a 1800
    if (-not $r.Started) { Write-OvnWarn "winget did not start ($($r.Error)). Using the official download instead."; return 'failed' }
    if ($r.TimedOut) { Write-OvnWarn 'winget was still busy after 30 minutes. Using the official download instead.'; return 'failed' }
    $outcome = Get-OvnWingetOutcome $r.Code
    if ($outcome -eq 'ok') { Write-OvnOk "winget finished: $Label"; return 'ok' }
    if ($outcome -eq 'intercepted') {
        Write-OvnWarn 'Something on this PC (antivirus web scanning, a VPN or a proxy) intercepts secure connections, so winget could not connect. Using the official download instead.'
    } else {
        Write-OvnWarn "winget could not add $Label (code $(Format-OvnCode $r.Code)). Using the official download instead."
    }
    return 'failed'
}

# Fetches a third-party installer, checks its signature (and its hash when one is known), and runs it.
function Invoke-OvnThirdParty {
    param([string]$Label, [string]$Url, [string]$File, [string]$Sha256, [string]$Arguments, [int[]]$OkCodes, [int]$TimeoutMinutes = 20)
    Write-OvnBegin Download "$Label from $(([Uri]$Url).Host)"
    if (-not (Save-OvnFile $Url $File)) { Write-OvnWarn "The download of $Label failed: $($Kit.WebError)"; return 'failed' }
    [void]$Kit.Downloads.Add($File)
    if ($Sha256) {
        $h = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
        if ($h -ne $Sha256) { Remove-OvnFile $File; Write-OvnWarn "$Label was not run: the file does not match its published checksum. Antivirus web scanning or a proxy may have changed it."; return 'failed' }
    }
    $sig = Get-OvnSignature $File
    if (-not $sig.Valid) { Remove-OvnFile $File; Write-OvnWarn "$Label was not run: its digital signature is not valid ($($sig.Status))."; return 'failed' }
    Write-OvnNote "Signature valid: $($sig.Signer)"
    Write-OvnBegin Install $Label
    $r = Start-OvnInstaller $File $Arguments $TimeoutMinutes
    if (-not $r.Started) {
        Remove-OvnFile $File
        if ($r.Declined) { Write-OvnWarn "The Windows permission box for $Label was declined."; return 'declined' }
        Write-OvnWarn "$Label did not start: $($r.Error)"
        return 'failed'
    }
    if ($r.TimedOut) { Write-OvnWarn "$Label was still running after $TimeoutMinutes minutes."; return 'failed' }
    Remove-OvnFile $File
    if ($OkCodes -contains [int]$r.Code) { Write-OvnOk "$Label finished."; return 'ok' }
    Write-OvnWarn "$Label ended with code $(Format-OvnCode $r.Code)."
    return 'failed'
}

function Install-OvnGitDirect {
    $json = Get-OvnWebText 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    if (-not $json) { Write-OvnWarn "Could not read the newest Git for Windows release from GitHub: $($Kit.WebError)"; return 'failed' }
    try { $rel = $json | ConvertFrom-Json } catch { Write-OvnWarn 'GitHub sent an unreadable answer about Git for Windows.'; return 'failed' }
    $asset = @($rel.assets | Where-Object { $_.name -match '^Git-.+-64-bit\.exe$' } | Select-Object -First 1)
    if (-not $asset.Count) { Write-OvnWarn 'The newest Git for Windows release has no 64-bit installer.'; return 'failed' }
    $sha = $null
    if ("$($asset[0].digest)" -match '^sha256:([0-9A-Fa-f]{64})$') { $sha = $Matches[1] }
    $file = Join-Path $Kit.Folder $asset[0].name
    $res = Invoke-OvnThirdParty -Label 'Git for Windows' -Url $asset[0].browser_download_url -File $file -Sha256 $sha `
        -Arguments '/VERYSILENT /NORESTART /NOCANCEL /SP- /SUPPRESSMSGBOXES /CURRENTUSER' -OkCodes @(0)
    if ($res -eq 'ok') {
        $cmd = Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd'
        if (Test-Path -LiteralPath (Join-Path $cmd 'git.exe')) { Add-OvnUserPath $cmd 'git' }
    }
    return $res
}

function Install-OvnFfmpegDirect {
    $url = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
    $zip = Join-Path $Kit.Folder 'ffmpeg-release-essentials.zip'
    Write-OvnBegin Download 'ffmpeg from www.gyan.dev'
    if (-not (Save-OvnFile $url $zip)) { Write-OvnWarn "The download of ffmpeg failed: $($Kit.WebError)"; return 'failed' }
    [void]$Kit.Downloads.Add($zip)
    $published = Get-OvnWebText ($url + '.sha256')
    if ($published -and $published.Trim() -match '^([0-9A-Fa-f]{64})') {
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $Matches[1]) {
            Remove-OvnFile $zip
            Write-OvnWarn 'ffmpeg was not unpacked: the file does not match its published checksum. Antivirus web scanning or a proxy may have changed it.'
            return 'failed'
        }
        Write-OvnNote 'The ffmpeg checksum matches.'
    } else {
        Write-OvnWarn 'The ffmpeg checksum could not be fetched, so the zip was not checked against it.'
    }
    $bin = Join-Path $env:LOCALAPPDATA 'Programs\ffmpeg\bin'
    Write-OvnBegin Install "ffmpeg into $bin"
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $null = New-Item -ItemType Directory -Path $bin -Force
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $count = 0
            foreach ($e in $archive.Entries) {
                if ($e.FullName -match '/bin/[^/]+$' -and $e.Name) {
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $bin $e.Name), $true)
                    $count++
                }
            }
        } finally { $archive.Dispose() }
        if (-not $count) { Write-OvnWarn 'The ffmpeg zip holds no bin folder.'; return 'failed' }
    } catch { Write-OvnWarn "ffmpeg could not be unpacked: $($_.Exception.Message)"; return 'failed' }
    Remove-OvnFile $zip
    Add-OvnUserPath $bin 'ffmpeg'
    return 'ok'
}

# ------------------------------------------------------------------ moving the old version aside
# These functions are loaded on their own by ci\test-move-aside.ps1, so they use only one another, Note, Warn,
# Stop-Install, cmdlets and .NET, and write nothing to the output stream except their return value.

function Long-Path([string]$Path) {
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return ('\\?\UNC\' + $Path.Substring(2)) }
    return ('\\?\' + $Path)
}

function Remove-Tree([string]$Path) {
    if (-not $Path) { return }
    $lp = Long-Path $Path
    if ([System.IO.File]::Exists($lp)) {
        try { [System.IO.File]::SetAttributes($lp, [System.IO.FileAttributes]::Normal); [System.IO.File]::Delete($lp) } catch { }
        return
    }
    if (-not [System.IO.Directory]::Exists($lp)) { return }
    try { [System.IO.Directory]::Delete($lp, $true); return } catch { }
    # Slow path: read-only files, or a folder some program uses as its working folder (it stays, empty).
    try {
        foreach ($f in [System.IO.Directory]::GetFiles($lp)) {
            try { [System.IO.File]::SetAttributes($f, [System.IO.FileAttributes]::Normal); [System.IO.File]::Delete($f) } catch { }
        }
    } catch { }
    try {
        foreach ($d in [System.IO.Directory]::GetDirectories($lp)) {
            $isLink = $false
            try { $isLink = (([System.IO.File]::GetAttributes($d) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) } catch { }
            if ($isLink) { try { [System.IO.Directory]::Delete($d, $false) } catch { } } else { Remove-Tree $d }
        }
    } catch { }
    try { [System.IO.Directory]::Delete($lp, $false) } catch { }
}

# True when the folder holds only what an Overnight install puts there.
function App-Only([string]$Folder) {
    $lp = Long-Path $Folder.TrimEnd('\')
    if (-not [System.IO.Directory]::Exists($lp)) { return $false }
    $dirs = @('resources', 'locales', 'swiftshader')
    $exts = @('.exe', '.dll', '.pak', '.dat', '.bin', '.json', '.txt', '.html', '.ico', '.log')
    foreach ($e in [System.IO.Directory]::GetFileSystemEntries($lp)) {
        $name = [System.IO.Path]::GetFileName($e)
        if ([System.IO.Directory]::Exists($e)) {
            if ($dirs -notcontains $name.ToLowerInvariant()) { return $false }
        } elseif ($exts -notcontains [System.IO.Path]::GetExtension($name).ToLowerInvariant()) {
            return $false
        }
    }
    return $true
}

# The running processes whose program lies inside the folder.
function Folder-Procs([string]$Folder) {
    if (-not $Folder) { return }
    $prefix = $Folder.TrimEnd('\') + '\'
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $p.Path } catch { }
        if ($path -and $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $p }
    }
}

# Moves every entry of Source into Destination. A folder that refuses to move as a whole is entered and emptied
# instead (it stays behind, empty). Returns the first path that would not move, or nothing.
function Move-Entries([string]$Source, [string]$Destination, [int]$Depth = 0) {
    $src = Long-Path $Source.TrimEnd('\')
    $dst = Long-Path $Destination.TrimEnd('\')
    if (-not [System.IO.Directory]::Exists($src)) { return }
    if (-not [System.IO.Directory]::Exists($dst)) { [void][System.IO.Directory]::CreateDirectory($dst) }
    $stuck = $null
    foreach ($e in @([System.IO.Directory]::GetFileSystemEntries($src))) {
        $target = [System.IO.Path]::Combine($dst, [System.IO.Path]::GetFileName($e))
        $isDir = [System.IO.Directory]::Exists($e)
        $moved = $false
        try {
            if ($isDir) {
                if (-not [System.IO.Directory]::Exists($target)) { [System.IO.Directory]::Move($e, $target); $moved = $true }
            } else {
                if ([System.IO.File]::Exists($target)) { [System.IO.File]::SetAttributes($target, [System.IO.FileAttributes]::Normal); [System.IO.File]::Delete($target) }
                [System.IO.File]::Move($e, $target)
                $moved = $true
            }
        } catch { }
        if ($moved) { continue }
        if ($isDir -and $Depth -lt 16) {
            $inner = Move-Entries $e $target ($Depth + 1)
            if ($inner -and -not $stuck) { $stuck = $inner }
        } elseif (-not $stuck) {
            $stuck = $e
        }
    }
    if ($stuck) {
        $plain = $stuck
        if ($plain.StartsWith('\\?\UNC\')) { $plain = '\\' + $plain.Substring(8) } elseif ($plain.StartsWith('\\?\')) { $plain = $plain.Substring(4) }
        return $plain
    }
}

# Puts the old version back from the aside folder. True when the install folder holds it again, without a marker,
# and the aside folder is gone.
function Put-Back([string]$Aside, [string]$InstallFolder, [string]$ExeName = 'Overnight.exe') {
    if (-not $Aside -or -not $InstallFolder) { return $false }
    $aside = $Aside.TrimEnd('\')
    $dir = $InstallFolder.TrimEnd('\')
    if (-not [System.IO.File]::Exists((Long-Path ([System.IO.Path]::Combine($aside, $ExeName))))) { return $false }
    Remove-Tree $dir
    $whole = $false
    if (-not [System.IO.Directory]::Exists((Long-Path $dir))) {
        try { [System.IO.Directory]::Move((Long-Path $aside), (Long-Path $dir)); $whole = $true } catch { }
    }
    if (-not $whole) {
        $stuck = Move-Entries $aside $dir 0
        if ($stuck) {
            try { [System.IO.File]::WriteAllText((Long-Path ([System.IO.Path]::Combine($aside, '.ovn-moved'))), $dir) } catch { }
            Warn "Part of the previous version could not be put back ($stuck). The next run of this setup finishes it."
            return $false
        }
        Remove-Tree $aside
    }
    $marker = Long-Path ([System.IO.Path]::Combine($dir, '.ovn-moved'))
    try { if ([System.IO.File]::Exists($marker)) { [System.IO.File]::Delete($marker) } } catch { }
    return $true
}

# Empties the install folder before an installer runs, so no installer has an old version to uninstall. Returns the
# aside folder, or nothing when the folder holds things Overnight did not put there. Stops when a file is held.
function Move-OldApp([string]$InstallFolder, [string]$ExeName = 'Overnight.exe') {
    $dir = $InstallFolder.TrimEnd('\')
    $aside = $dir + '.ovn-old'
    if (-not (App-Only $dir)) {
        Note "Overnight's folder holds files that are not part of Overnight, so it is not moved aside: $dir"
        return
    }
    Remove-Tree $aside
    if ([System.IO.Directory]::Exists((Long-Path $aside))) {
        Note "An earlier aside folder could not be removed ($aside), so the old version is not moved aside."
        return
    }
    $how = $null
    for ($i = 0; $i -lt 4 -and -not $how; $i++) {
        try { [System.IO.Directory]::Move((Long-Path $dir), (Long-Path $aside)); $how = 'in one step' } catch { Start-Sleep -Seconds 1 }
    }
    if (-not $how) {
        # A program has the folder as its working folder: move what is inside it instead.
        [void][System.IO.Directory]::CreateDirectory((Long-Path $aside))
        [System.IO.File]::WriteAllText((Long-Path ([System.IO.Path]::Combine($aside, '.ovn-moved'))), $dir)
        $stuck = $null
        for ($pass = 0; $pass -lt 4; $pass++) {
            $stuck = Move-Entries $dir $aside 0
            if (-not $stuck) { break }
            Start-Sleep -Milliseconds 500
        }
        if ($stuck) {
            $back = Move-Entries $aside $dir 0
            if (-not $back) {
                $marker = Long-Path ([System.IO.Path]::Combine($dir, '.ovn-moved'))
                try { if ([System.IO.File]::Exists($marker)) { [System.IO.File]::Delete($marker) } } catch { }
                Remove-Tree $aside
            } else {
                try { [System.IO.File]::WriteAllText((Long-Path ([System.IO.Path]::Combine($aside, '.ovn-moved'))), $dir) } catch { }
            }
            $names = @(Folder-Procs $dir | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
            $who = 'Another program'
            if ($names.Count) { $who = ($names -join ', ') }
            Stop-Install ("Overnight was not updated: a file in its folder is in use ($stuck). $who has it open. Close it and run the same command again; if you cannot find the program, restart the PC first. The version you have still works.")
        }
        $how = 'entry by entry (a program is working in the folder)'
    }
    [System.IO.File]::WriteAllText((Long-Path ([System.IO.Path]::Combine($aside, '.ovn-moved'))), $dir)
    Note "The previous version was moved aside $how, to $aside"
    return $aside
}

# Finishes or clears an aside folder left by an earlier run (this script's or the app's own installer).
function Recover-Aside([string]$InstallFolder, [string]$ExeName = 'Overnight.exe') {
    $dir = $InstallFolder.TrimEnd('\')
    $aside = $dir + '.ovn-old'
    if (-not [System.IO.Directory]::Exists((Long-Path $aside))) { return }
    $asideExe = [System.IO.File]::Exists((Long-Path ([System.IO.Path]::Combine($aside, $ExeName))))
    $marked = [System.IO.File]::Exists((Long-Path ([System.IO.Path]::Combine($aside, '.ovn-moved'))))
    $dirExe = [System.IO.File]::Exists((Long-Path ([System.IO.Path]::Combine($dir, $ExeName))))
    if ($asideExe -and ($marked -or -not $dirExe)) {
        if (Put-Back $aside $dir $ExeName) { Note 'An earlier update stopped half way. The version from before it is back in place.' }
        else { Warn 'An earlier update stopped half way, and the version from before it could not be fully put back yet.' }
        return
    }
    if (-not $marked) {
        Remove-Tree $aside
        if ([System.IO.Directory]::Exists((Long-Path $aside))) { Note "The leftover of an earlier update could not be removed yet: $aside" }
        else { Note 'Removed the leftover of an earlier update.' }
        return
    }
    Note "A marked aside folder without the app was left as it is: $aside"
}

# ------------------------------------------------------------------ Overnight's files and processes

function Get-OvnDefaultAppDir { return (Join-Path $env:LOCALAPPDATA 'Programs\overnight') }

# Where Overnight is installed: the folder electron-builder recorded for the uninstall entry, the entry's own
# InstallLocation, or the folder of its uninstaller; else the default folder.
function Get-OvnInstallFolder {
    if ($Kit.TestAppDir) { return $Kit.TestAppDir }
    $cands = New-Object System.Collections.ArrayList
    foreach ($key in @(Get-ChildItem -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue)) {
        $e = $null
        try { $e = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop } catch { continue }
        if ($e.DisplayName -ne 'Overnight') { continue }
        try {
            $own = Get-ItemProperty -LiteralPath ('HKCU:\Software\' + $key.PSChildName) -ErrorAction Stop
            if ($own.InstallLocation) { [void]$cands.Add([string]$own.InstallLocation) }
        } catch { }
        if ($e.InstallLocation) { [void]$cands.Add([string]$e.InstallLocation) }
        if ($e.UninstallString) {
            $exe = $null
            if ("$($e.UninstallString)" -match '^\s*"([^"]+)"') { $exe = $Matches[1] }
            elseif ("$($e.UninstallString)" -match '^\s*(.+?\.exe)') { $exe = $Matches[1] }
            if ($exe) { try { [void]$cands.Add([System.IO.Path]::GetDirectoryName($exe)) } catch { } }
        }
    }
    $clean = @($cands | ForEach-Object { (Get-OvnUnquoted $_).TrimEnd('\') } | Where-Object { $_ })
    foreach ($c in $clean) { if ([System.IO.File]::Exists([System.IO.Path]::Combine($c, 'Overnight.exe'))) { return $c } }
    foreach ($c in $clean) { if ([System.IO.Directory]::Exists($c + '.ovn-old')) { return $c } }
    return (Get-OvnDefaultAppDir)
}

function Read-OvnInstalledVersion([string]$Dir) {
    if ($Kit.TestAppDir) {
        $f = [System.IO.Path]::Combine($Dir, 'version.txt')
        if ([System.IO.File]::Exists($f)) { return ([System.IO.File]::ReadAllText($f).Trim()) }
        return $null
    }
    $exe = [System.IO.Path]::Combine($Dir, 'Overnight.exe')
    if (-not [System.IO.File]::Exists($exe)) { return $null }
    try { return (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion } catch { return '' }
}

function Find-OvnApp {
    $dir = Get-OvnInstallFolder
    $exe = [System.IO.Path]::Combine($dir, 'Overnight.exe')
    $ver = Read-OvnInstalledVersion $dir
    if ($Kit.TestAppDir) { if (-not $ver) { return $null } }
    elseif (-not [System.IO.File]::Exists($exe)) { return $null }
    return @{ Exe = $exe; Dir = $dir; Version = (Format-OvnVersion "$ver") }
}

function Get-OvnAppProcesses([string]$Dir) {
    if (-not $Dir) { return @() }
    return @(Folder-Procs $Dir)
}

# Closes Overnight's processes (everything running from its folder). Returns how many are left.
function Close-OvnAppProcesses([string]$Dir, [int]$Seconds) {
    foreach ($p in @(Get-OvnAppProcesses $Dir)) {
        try { if ($p.MainWindowHandle -ne [IntPtr]::Zero) { [void]$p.CloseMainWindow() } } catch { }
    }
    $start = Get-Date
    $forced = $false
    while (((Get-Date) - $start).TotalSeconds -lt $Seconds) {
        $left = @(Get-OvnAppProcesses $Dir)
        if (-not $left.Count) { return 0 }
        if (-not $forced -and ((Get-Date) - $start).TotalSeconds -ge 5) {
            foreach ($p in $left) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
            $forced = $true
        }
        Start-Sleep -Milliseconds 500
    }
    return @(Get-OvnAppProcesses $Dir).Count
}

# Removes the program folder only (the whole folder when it holds only Overnight's own entries, else its
# resources folder). The data folder and the videos are never in it.
function Remove-OvnProgramFolder([string]$Dir) {
    if (App-Only $Dir) { Remove-Tree $Dir } else { Remove-Tree ([System.IO.Path]::Combine($Dir, 'resources')) }
}

# ------------------------------------------------------------------ release files (real, or a test release folder)

function Get-OvnReleaseSource([string]$Name, [string]$Version) {
    if ($Kit.TestBase) { return [System.IO.Path]::Combine($Kit.TestBase, $Name) }
    if ($Version) { return ($Kit.ReleaseBase + "download/v$Version/$Name") }
    return ($Kit.ReleaseBase + "latest/download/$Name")
}

function Get-OvnReleaseText([string]$Name, [string]$Version) {
    $src = Get-OvnReleaseSource $Name $Version
    if ($Kit.TestBase) {
        if ([System.IO.File]::Exists($src)) { return [System.IO.File]::ReadAllText($src) }
        $Kit.WebError = "$Name is not in the test release"
        return $null
    }
    return (Get-OvnWebText $src)
}

function Save-OvnReleaseFile([string]$Name, [string]$Version, [string]$Destination, [int]$Tries = 3) {
    $src = Get-OvnReleaseSource $Name $Version
    if ($Kit.TestBase) {
        if (-not [System.IO.File]::Exists($src)) { $Kit.WebError = "$Name is not in the test release"; return $false }
        if (-not (Test-Path -LiteralPath $Kit.Folder)) { $null = New-Item -ItemType Directory -Path $Kit.Folder -Force }
        Copy-Item -LiteralPath $src -Destination $Destination -Force
        return $true
    }
    if (-not (Test-Path -LiteralPath $Kit.Folder)) { $null = New-Item -ItemType Directory -Path $Kit.Folder -Force }
    return (Save-OvnFile $src $Destination $Tries)
}

# ------------------------------------------------------------------ the list of Overnight's files

# A version's list as published on its release page, fetched once per run into the download folder.
function Get-OvnReleaseFileList([string]$Version) {
    if (-not $Version) { return $null }
    $name = "install-manifest-$Version.json"
    $dest = Join-Path $Kit.Folder $name
    if (-not $Kit.ListTried.ContainsKey($Version)) {
        $Kit.ListTried[$Version] = $true
        if (-not (Test-Path -LiteralPath $dest)) {
            if (Save-OvnReleaseFile $name $Version $dest 1) { [void]$Kit.Downloads.Add($dest) }
        }
    }
    if ((Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -gt 100) { return $dest }
    return $null
}

function Get-OvnFileList([string]$Dir, [string]$Version) {
    $own = [System.IO.Path]::Combine($Dir, 'resources\install-manifest.json')
    if ([System.IO.File]::Exists((Long-Path $own))) { return $own }
    return (Get-OvnReleaseFileList $Version)
}

function Read-OvnListHeader([string]$ListPath) {
    $h = @{ Version = $null; Bytes = $null; Files = $false }
    try {
        # (a reader that is closed at once: breaking out of ReadLines would keep the file open)
        $sr = New-Object System.IO.StreamReader($ListPath)
        try { $first = $sr.ReadLine() } finally { $sr.Dispose() }
        if ($first -match '"version"\s*:\s*"([^"]*)"') { $h.Version = $Matches[1] }
        if ($first -match '"bytes"\s*:\s*(\d+)') { $h.Bytes = [double]$Matches[1] }
        $h.Files = ($first -match '"files"\s*:\s*\[')
    } catch { }
    return $h
}

# Every file under a folder, as relative path (forward slashes) -> size. Sees paths over 260 characters.
function Get-OvnFileSizes([string]$Folder) {
    $sizes = @{}
    $root = (Long-Path $Folder.TrimEnd('\'))
    if (-not [System.IO.Directory]::Exists($root)) { return $sizes }
    $cut = $root.Length + 1
    $stack = New-Object System.Collections.Stack
    $stack.Push($root)
    while ($stack.Count) {
        $d = $stack.Pop()
        try { foreach ($f in (New-Object System.IO.DirectoryInfo $d).GetFiles()) { $sizes[$f.FullName.Substring($cut).Replace('\', '/')] = $f.Length } } catch { }
        try {
            foreach ($s in (New-Object System.IO.DirectoryInfo $d).GetDirectories()) {
                if (($s.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($s.FullName) }
            }
        } catch { }
    }
    return $sizes
}

# Compares a list with the files on disk. Missing, wrong size and the first three offending paths.
function Compare-OvnFileList([string]$ListPath, [string]$ResourcesDir, [string]$Version) {
    $r = @{ HasList = $true; Total = 0; Missing = 0; Wrong = 0; Complete = $false; Line = ''; Reason = '' }
    $head = Read-OvnListHeader $ListPath
    $bad = New-Object System.Collections.ArrayList
    $entries = New-Object System.Collections.ArrayList
    $first = $true
    foreach ($line in [System.IO.File]::ReadLines($ListPath)) {
        if ($first) { $first = $false; continue }
        if ($line -match '^\s*\[\s*"((?:[^"\\]|\\.)*)"\s*,\s*(null|\d+)\s*\]') {
            $p = $Matches[1]
            if ($p.Contains('\')) { $p = [regex]::Unescape($p) }
            [void]$entries.Add(@($p, $Matches[2]))
        }
    }
    if ($head.Version -and $Version -and (Compare-OvnVersion $head.Version $Version) -ne 0) {
        $r.Reason = "the file list belongs to Overnight $($head.Version)"
    }
    $have = Get-OvnFileSizes $ResourcesDir
    foreach ($e in $entries) {
        $p = $e[0]
        if ($p -match '(^|/)__pycache__/' -or $p -match '\.pyc$' -or $p -match '(^|/)node_modules/\.cache/') { continue }
        $r.Total++
        if (-not $have.ContainsKey($p)) {
            $r.Missing++
            if ($bad.Count -lt 3) { [void]$bad.Add($p) }
        } elseif ($e[1] -ne 'null' -and [long]$e[1] -ne [long]$have[$p]) {
            $r.Wrong++
            if ($bad.Count -lt 3) { [void]$bad.Add("$p (wrong size)") }
        }
    }
    if (-not $r.Total -and -not $r.Reason) { $r.Reason = 'the file list is empty' }
    $text = ''
    if ($r.Missing) { $text = "$($r.Missing) of $($r.Total) files missing" }
    if ($r.Wrong) { if ($text) { $text += ', ' }; $text += "$($r.Wrong) of $($r.Total) with the wrong size" }
    if (-not $text) { $text = 'not complete' }
    if ($r.Reason) { $text += " ($($r.Reason))" }
    if ($bad.Count) { $text += ': ' + ($bad -join ', ') }
    $r.Line = $text
    $r.Complete = ($r.Total -gt 0) -and -not $r.Missing -and -not $r.Wrong -and -not $r.Reason
    return $r
}

function Test-OvnInstalledFiles([string]$Dir, [string]$Version) {
    $list = Get-OvnFileList $Dir $Version
    if (-not $list) { return @{ HasList = $false; Complete = $false; Total = 0; Line = '' } }
    return (Compare-OvnFileList $list ([System.IO.Path]::Combine($Dir, 'resources')) $Version)
}

# ------------------------------------------------------------------ room on the drives

function Format-OvnNumber([double]$Value) {
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.0}', [Math]::Round($Value, 1, [MidpointRounding]::AwayFromZero))
}

# What each drive needs while the install runs, in GB: the download folder's drive twice the download plus the
# unpacked app, the install drive the unpacked app (both on one drive: added), plus 0.5 GB per drive.
function Get-OvnSpaceNeeds([string]$TempRoot, [string]$InstallRoot, [double]$UnpackedGB) {
    $download = 0.8
    $needs = New-Object System.Collections.Specialized.OrderedDictionary
    $t = $TempRoot.ToUpperInvariant(); $i = $InstallRoot.ToUpperInvariant()
    $needs[$t] = 2 * $download + $UnpackedGB
    if ($needs.Contains($i)) { $needs[$i] = $needs[$i] + $UnpackedGB } else { $needs[$i] = $UnpackedGB }
    foreach ($k in @($needs.Keys)) { $needs[$k] = [Math]::Round($needs[$k] + 0.5, 1, [MidpointRounding]::AwayFromZero) }
    return $needs
}

# Stops before anything is fetched or moved when a drive is short. Returns the unpacked size used, in GB.
function Test-OvnSpace([string]$Target, [string]$AppDir) {
    $unpacked = 2.7
    $list = Get-OvnReleaseFileList $Target
    if ($list) { $h = Read-OvnListHeader $list; if ($h.Bytes) { $unpacked = $h.Bytes / 1GB + 0.2 } }
    $needs = Get-OvnSpaceNeeds ([System.IO.Path]::GetPathRoot($Kit.Folder)) ([System.IO.Path]::GetPathRoot($AppDir)) $unpacked
    foreach ($root in @($needs.Keys)) {
        $need = $needs[$root]
        $free = Get-OvnFreeBytes $root
        $drive = $root.TrimEnd('\')
        if ($null -eq $free) { Write-OvnNote "Free space on $drive could not be measured, so it was not checked."; continue }
        $freeGB = $free / 1GB
        if ($freeGB -lt $need) {
            $more = $need - $freeGB + 0.1
            Stop-OvnSetup ("There is not enough free disk space to install Overnight: {0} has {1} GB free and the install needs about {2} GB while it runs. Free {3} GB or more, for example by emptying the Recycle Bin or moving old videos or downloads to another drive. Nothing was changed." -f $drive, (Format-OvnNumber $freeGB), (Format-OvnNumber $need), (Format-OvnNumber $more)) 'Free the space, then run the same command again.'
        }
        Write-OvnOk ("{0} has {1} GB free; the install needs about {2} GB there." -f $drive, (Format-OvnNumber $freeGB), (Format-OvnNumber $need))
    }
    return $unpacked
}
# When Overnight closes it may run its own pending update. Wait (only watch, never touch) until that is done.
function Wait-OvnAppUpdater([int]$Seconds) {
    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $Seconds) {
        if (-not @(Get-Process -Name 'Overnight-Setup*' -ErrorAction SilentlyContinue).Count) { return }
        Start-Sleep -Seconds 2
    }
}

function Read-OvnDataPointer {
    $f = Join-Path $env:APPDATA 'Overnight\data-location.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try {
        $j = [System.IO.File]::ReadAllText($f) | ConvertFrom-Json
        if ($j.dir -is [string] -and $j.dir.Trim()) { return $j.dir.Trim() }
    } catch { }
    return $null
}

function Get-OvnDataDir {
    $ptr = Read-OvnDataPointer
    if ($ptr) { return $ptr }
    return (Join-Path $env:APPDATA 'Overnight')
}

function Test-OvnWritable([string]$Dir) {
    try {
        $null = New-Item -ItemType Directory -Path $Dir -Force
        $f = Join-Path $Dir ('.overnight-write-check-' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($f, 'ok')
        Remove-Item -LiteralPath $f -Force
        return $true
    } catch { return $false }
}

# Writes a JSON file only when it does not exist yet. $true when written.
function Write-OvnNewJson([string]$Path, [string]$Json) {
    if (Test-Path -LiteralPath $Path) { return $false }
    $bytes = $Kit.Utf8.GetBytes($Json)
    try { $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write) } catch [System.IO.IOException] { return $false }
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    return $true
}

function Write-OvnFirstInstallData($Plan) {
    $appData = Join-Path $env:APPDATA 'Overnight'
    foreach ($d in @($appData, $Plan.DataDir, $Plan.VideosDir)) { $null = New-Item -ItemType Directory -Path $d -Force }
    $ptr = Join-Path $appData 'data-location.json'
    if (Write-OvnNewJson $ptr ('{"dir": ' + (ConvertTo-OvnJsonText $Plan.DataDir) + '}')) { Write-OvnOk "Overnight's data will live in $($Plan.DataDir) (pointer: $ptr)." }
    else { Write-OvnNote "$ptr already exists and was left as it is." }
    $set = [System.IO.Path]::Combine($Plan.DataDir, 'settings.json')
    if (Write-OvnNewJson $set ('{"workspace": ' + (ConvertTo-OvnJsonText $Plan.VideosDir) + '}')) { Write-OvnOk "New videos will be saved in $($Plan.VideosDir)." }
    else { Write-OvnNote "$set already exists and was left as it is." }
    $Kit.VideosDir = $Plan.VideosDir
}

# ------------------------------------------------------------------ steps

function Read-OvnSwitches {
    $Kit.Dry = Test-OvnNonEmpty $env:OVERNIGHT_SETUP_DRY
    $Kit.NoOpen = Test-OvnOn $env:OVERNIGHT_NO_OPEN
    $Kit.CloseApp = Test-OvnOn $env:OVERNIGHT_CLOSE_APP
    $Kit.Reinstall = Test-OvnOn $env:OVERNIGHT_REINSTALL
    $Kit.NoWinget = Test-OvnOn $env:OVERNIGHT_SETUP_NO_WINGET
    $Kit.InstallDir = "$env:OVERNIGHT_INSTALL_DIR"
    if ("$env:OVERNIGHT_TEST_RELEASE_BASE".Trim()) { $Kit.TestBase = "$env:OVERNIGHT_TEST_RELEASE_BASE".Trim() }
}

# A test release (OVERNIGHT_TEST_RELEASE_BASE): checked here, so a test can never touch the real Overnight.
function Initialize-OvnTestRelease {
    if (-not $Kit.TestBase) { return }
    $Kit.TestBase = [System.IO.Path]::GetFullPath($Kit.TestBase).TrimEnd('\')
    $raw = "$env:OVERNIGHT_TEST_APPDIR".Trim().Trim('"')
    if (-not $raw) { Stop-OvnSetup 'OVERNIGHT_TEST_RELEASE_BASE is set without OVERNIGHT_TEST_APPDIR.' 'Set OVERNIGHT_TEST_APPDIR to a test install folder.' }
    $appDir = [System.IO.Path]::GetFullPath($raw).TrimEnd('\')
    if ($appDir -match '(?i)Programs\\overnight$') { Stop-OvnSetup "OVERNIGHT_TEST_APPDIR points at a real Overnight folder: $appDir" 'Use a scratch folder for tests.' }
    $Kit.TestAppDir = $appDir
    $free = "$env:OVERNIGHT_TEST_FREE_GB".Trim()
    if ($free) { $Kit.TestFreeGB = [double]::Parse($free, [System.Globalization.CultureInfo]::InvariantCulture) }
    $Kit.Steps = 6
    Write-OvnOut "Test release: $($Kit.TestBase); test install folder: $appDir" 'Yellow'
}

function Write-OvnIntro {
    Write-OvnLog ''
    Write-OvnLog ('---- run started ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    Write-OvnOut 'Overnight setup for Windows'
    Write-OvnOut 'This puts Overnight on this PC, with the tools it needs: git, ffmpeg, Python 3.12, the Microsoft'
    Write-OvnOut 'Visual C++ runtime and Claude Code. Tools that already work are kept as they are.'
    Write-OvnOut "It takes 5 to 20 minutes. Log: $($Kit.Log)"
    if ($Kit.Dry) { Write-OvnOut 'Test mode: this run only looks and reports what it would do. Nothing will be changed.' 'Yellow' }
    $set = @()
    if ($Kit.NoOpen) { $set += 'OVERNIGHT_NO_OPEN' }
    if ($Kit.CloseApp) { $set += 'OVERNIGHT_CLOSE_APP' }
    if ($Kit.Reinstall) { $set += 'OVERNIGHT_REINSTALL' }
    if ($Kit.InstallDir) { $set += 'OVERNIGHT_INSTALL_DIR' }
    if ($Kit.NoWinget) { $set += 'OVERNIGHT_SETUP_NO_WINGET' }
    if ($set.Count) { Write-OvnOut ('Settings in use: ' + ($set -join ', ')) }
}

function Get-OvnArchitecture {
    $a = $null
    try { $a = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name PROCESSOR_ARCHITECTURE -ErrorAction Stop).PROCESSOR_ARCHITECTURE } catch { }
    if (-not $a) { $a = $env:PROCESSOR_ARCHITEW6432 }
    if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }
    if ($a -eq 'AMD64') { return 'x64' }
    if ($a) { return "$a" }
    return 'unknown'
}

function Invoke-OvnComputerStep {
    Write-OvnStep 'This computer'
    $isWindows = ($env:OS -eq 'Windows_NT') -and ("$($PSVersionTable.Platform)" -ne 'Unix')
    if (-not $isWindows) {
        Stop-OvnSetup 'This script is for Windows only.' "A Mac has its own script, install.sh. The README explains how to run it: $($Kit.Repo)"
    }
    $build = [Environment]::OSVersion.Version.Build
    $arch = Get-OvnArchitecture
    if (-not [Environment]::Is64BitOperatingSystem) {
        Stop-OvnSetup 'This PC runs 32-bit Windows. Overnight needs 64-bit Windows.' 'Overnight needs a 64-bit Windows 10 (version 1809 or newer) or Windows 11 PC.'
    }
    if ($build -lt 17763) {
        Stop-OvnSetup "This PC runs Windows build $build. Overnight needs Windows 10 version 1809 (build 17763) or newer, or Windows 11." 'Update Windows in Settings > Windows Update, then run the same command again.'
    }
    $name = 'Windows 10'
    if ($build -ge 22000) { $name = 'Windows 11' }
    Write-OvnOk "$name, build $build, $arch"
    if ($arch -eq 'ARM64') {
        Write-OvnWarn 'This PC has an ARM processor. Overnight runs its x64 version here under emulation, which is untested: it may be slow or fail.'
    }
}

function Test-OvnAppDataRedirect {
    $result = @{ Checked = $false; Package = $null; Error = '' }
    $name = 'overnight-probe-' + [guid]::NewGuid().ToString('N') + '.tmp'
    $probe = Join-Path $env:APPDATA $name
    $hits = @()
    try {
        [System.IO.File]::WriteAllText($probe, 'probe')
        $packages = Join-Path $env:LOCALAPPDATA 'Packages'
        if (Test-Path -LiteralPath $packages) {
            $hits = @(Get-ChildItem -LiteralPath $packages -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName ('LocalCache\Roaming\' + $name) } |
                Where-Object { Test-Path -LiteralPath $_ })
        }
        $result.Checked = $true
        if ($hits.Count) { $result.Package = Get-OvnPackageFromHit $hits[0] }
    } catch {
        $result.Error = $_.Exception.Message
    } finally {
        try { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force } } catch { }
        foreach ($h in $hits) { try { if (Test-Path -LiteralPath $h) { Remove-Item -LiteralPath $h -Force } } catch { } }
    }
    return $result
}

function Invoke-OvnRedirectStep {
    Write-OvnStep 'Where this window writes app data'
    $r = Test-OvnAppDataRedirect
    if (-not $r.Checked) { Write-OvnNote "The check could not run ($($r.Error)). Carrying on."; return }
    if ($r.Package -and $Kit.TestBase) {
        Write-OvnNote "AppData is redirected into the app package $($r.Package). With a test release this is only noted."
        return
    }
    if ($r.Package) {
        Stop-OvnSetup "This window's AppData is redirected into the app package $($r.Package), so Overnight would be set up in a hidden copy. Nothing was changed." "Open your own PowerShell from the Start menu (type PowerShell, press Enter) and paste: $($Kit.OneLiner)"
    }
    Write-OvnOk 'AppData is the real one.'
}

function Invoke-OvnSpaceStep {
    Write-OvnStep 'Disk space and Smart App Control'
    $sys = "$env:SystemDrive\"
    $free = Get-OvnFreeBytes $sys
    if ($null -eq $free) { Write-OvnNote "Free space on $sys could not be read." }
    elseif ($free -lt 10GB) { Write-OvnWarn "Only $(Format-OvnGB $free) free on $sys. Overnight and its tools take several GB, and videos take more. Free some space soon." }
    else { Write-OvnOk "$(Format-OvnGB $free) free on $sys" }
    $sac = $null
    $sac = Get-OvnSmartAppControl
    if ($sac -eq 1) {
        Write-OvnWarn 'Smart App Control is On. It may block Overnight itself and its installer, because Overnight is not code-signed yet, and the Python packages it sets up (WinError 4551).'
        Write-OvnWarn 'Turning it off is your decision: Windows Security > App & browser control > Smart App Control. On most Windows 11 versions it can only be turned on again by resetting Windows.'
    } elseif ($sac -eq 2) {
        Write-OvnNote 'Smart App Control is in evaluation mode. Windows may turn it On later, and then it may block Overnight.'
    } else {
        Write-OvnOk 'Smart App Control is off or not on this PC.'
    }
}

function Invoke-OvnWingetStep {
    Write-OvnStep 'winget'
    Update-OvnSessionPath
    if ($Kit.NoWinget) { Write-OvnWarn 'winget is skipped (OVERNIGHT_SETUP_NO_WINGET=1). The official downloads are used instead.'; return }
    $w = @(Get-OvnCommandPaths 'winget' | Select-Object -First 1)
    if ($w.Count) { $Kit.Winget = $w[0]; Write-OvnOk "winget is available: $($w[0])" }
    else { Write-OvnWarn 'winget is not on this PC. That is fine: the official downloads are used instead.' }
}

function Invoke-OvnGitStep {
    Write-OvnStep 'git (keeps the history of every project)'
    $found = Find-OvnTool (Get-OvnGitCandidates) @('--version') '^git version'
    if ($found) { Write-OvnOk "git is here: $($found.Path) ($($found.Version))"; Confirm-OvnOnPath $found.Path 'git'; return }
    if ($Kit.Dry) { Write-OvnNote 'git is missing. A real run would add Git for Windows for this user (winget first, then the official download).'; return }
    Write-OvnNote 'git is missing. Windows may ask for permission for Git: accepting is fine, declining is fine too.'
    $res = Install-OvnWithWinget 'Git.Git' 'Git for Windows' -UserScope
    Update-OvnSessionPath
    $found = Find-OvnTool (Get-OvnGitCandidates) @('--version') '^git version'
    if (-not $found -and $res -ne 'ok') {
        $res = Install-OvnGitDirect
        Update-OvnSessionPath
        $found = Find-OvnTool (Get-OvnGitCandidates) @('--version') '^git version'
    }
    if ($found) { Write-OvnOk "git is here: $($found.Path) ($($found.Version))"; Confirm-OvnOnPath $found.Path 'git'; return }
    if ($res -eq 'ok') { Add-OvnProblem 'git was added but cannot be found yet.' 'Open a new PowerShell window and run the same command again.' }
    else { Add-OvnProblem 'git could not be added (the lines above say why).' 'Check the internet connection, then run the same command again.' }
}

function Invoke-OvnFfmpegStep {
    Write-OvnStep 'ffmpeg (sound and the video export)'
    $found = Find-OvnTool (Get-OvnFfmpegCandidates) @('-hide_banner', '-version') '^ffmpeg version'
    if ($found) { Write-OvnOk "ffmpeg is here: $($found.Path) ($($found.Version))"; Confirm-OvnOnPath $found.Path 'ffmpeg'; return }
    if ($Kit.Dry) { Write-OvnNote 'ffmpeg is missing. A real run would add it for this user (winget first, then the official gyan.dev build).'; return }
    $res = Install-OvnWithWinget 'Gyan.FFmpeg' 'ffmpeg'
    Update-OvnSessionPath
    $found = Find-OvnTool (Get-OvnFfmpegCandidates) @('-hide_banner', '-version') '^ffmpeg version'
    if (-not $found -and $res -ne 'ok') {
        $res = Install-OvnFfmpegDirect
        Update-OvnSessionPath
        $found = Find-OvnTool (Get-OvnFfmpegCandidates) @('-hide_banner', '-version') '^ffmpeg version'
    }
    if ($found) { Write-OvnOk "ffmpeg is here: $($found.Path) ($($found.Version))"; Confirm-OvnOnPath $found.Path 'ffmpeg'; return }
    if ($res -eq 'ok') { Add-OvnProblem 'ffmpeg was added but cannot be found yet.' 'Open a new PowerShell window and run the same command again.' }
    else { Add-OvnProblem 'ffmpeg could not be added (the lines above say why).' 'Check the internet connection, then run the same command again.' }
}

function Get-OvnPyProbeFile {
    $file = Join-Path $Kit.Folder 'pyprobe.py'
    $code = @(
        'import os, struct, sys'
        'missing = []'
        "for name in ('venv', 'ensurepip', 'ssl'):"
        '    try:'
        '        __import__(name)'
        '    except Exception:'
        '        missing.append(name)'
        "conda = 1 if os.path.isdir(os.path.join(sys.prefix, 'conda-meta')) else 0"
        "exe = sys.executable.encode('utf-8', 'replace').hex()"
        "print('pyprobe|%d|%d|%d|%d|%s|%s' % (sys.version_info[0], sys.version_info[1], struct.calcsize('P') * 8, conda, ','.join(missing), exe))"
    ) -join "`n"
    if (-not (Test-Path -LiteralPath $Kit.Folder)) { $null = New-Item -ItemType Directory -Path $Kit.Folder -Force }
    [System.IO.File]::WriteAllText($file, $code + "`n", $Kit.Utf8)
    return $file
}

function Invoke-OvnPyProbe([string]$Exe) {
    if (Test-OvnStubPath $Exe) { return @{ Ran = $false; Asked = $Exe; Exe = $Exe } }
    $r = Invoke-OvnProgram $Exe @('-I', '-B', (Get-OvnPyProbeFile)) 60
    if (-not $r.Started -or $r.TimedOut) { return @{ Ran = $false; Asked = $Exe; Exe = $Exe } }
    $line = @($r.Lines | Where-Object { $_ -like 'pyprobe|*' } | Select-Object -First 1)
    if (-not $line.Count) { return @{ Ran = $false; Asked = $Exe; Exe = $Exe } }
    return (ConvertFrom-OvnPyProbe $line[0] $Exe)
}

function Get-OvnPythonFolderCandidates {
    $base = Join-Path $env:LOCALAPPDATA 'Programs\Python'
    if (-not (Test-Path -LiteralPath $base)) { return @() }
    $dirs = @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^Python3(\d+)$' } |
        Sort-Object { [int]($_.Name.Substring(7)) } -Descending)
    return @($dirs | ForEach-Object { Join-Path $_.FullName 'python.exe' } | Where-Object { Test-Path -LiteralPath $_ })
}

# Works out the Python Overnight would pick: the full path in its settings, then the first python on the PATH
# (when the app would accept its version), then the newest per-user python.org Python. All probes are returned too.
function Get-OvnPythonChoice {
    $choice = @{ Pick = $null; Source = ''; All = New-Object System.Collections.ArrayList }
    $settingsFile = [System.IO.Path]::Combine((Get-OvnDataDir), 'settings.json')
    $fromSettings = $null
    if (Test-Path -LiteralPath $settingsFile) {
        try { $fromSettings = Get-OvnSettingsPython ([System.IO.File]::ReadAllText($settingsFile)) } catch { }
    }
    if ($fromSettings -and [System.IO.Path]::IsPathRooted($fromSettings) -and (Test-Path -LiteralPath $fromSettings -PathType Leaf)) {
        $p = Invoke-OvnPyProbe $fromSettings
        [void]$choice.All.Add($p)
        $choice.Pick = $p; $choice.Source = 'Overnight''s settings (Tool paths)'
    }
    $onPath = @(Get-OvnCommandPaths 'python' | Where-Object { -not (Test-OvnStubPath $_) })
    $firstOnPath = $null
    foreach ($exe in $onPath) {
        $p = Invoke-OvnPyProbe $exe
        [void]$choice.All.Add($p)
        if (-not $firstOnPath) { $firstOnPath = $p }
    }
    $folders = @()
    foreach ($exe in (Get-OvnPythonFolderCandidates)) {
        if (@($choice.All | Where-Object { $_.Asked -eq $exe }).Count) { continue }
        $p = Invoke-OvnPyProbe $exe
        [void]$choice.All.Add($p)
        $folders += $p
    }
    if (-not $choice.Pick -and (Test-OvnAppWouldAccept $firstOnPath)) { $choice.Pick = $firstOnPath; $choice.Source = 'the first python on the PATH' }
    if (-not $choice.Pick) {
        $f = @($folders | Where-Object { Test-OvnAppWouldAccept $_ } | Select-Object -First 1)
        if ($f.Count) { $choice.Pick = $f[0]; $choice.Source = 'the newest Python in your user Programs folder' }
    }
    if (-not $choice.Pick -and $firstOnPath) { $choice.Pick = $firstOnPath; $choice.Source = 'the first python on the PATH' }
    if (-not $choice.Pick -and $folders.Count) { $choice.Pick = $folders[0]; $choice.Source = 'the newest Python in your user Programs folder' }
    return $choice
}

function Get-OvnUsablePython($Choice) {
    $u = @($Choice.All | Where-Object { -not (Get-OvnPythonVerdict $_) } | Select-Object -First 1)
    if ($u.Count) { return $u[0] }
    return $null
}

function Write-OvnPythonOk($Probe, [string]$Source) {
    Write-OvnOk ("Overnight will use Python {0}.{1} ({2}-bit) from {3}: {4}" -f $Probe.Major, $Probe.Minor, $Probe.Bits, $Source, $Probe.Exe)
}

function Invoke-OvnPythonStep {
    Write-OvnStep 'Python (Overnight builds its own environment from it)'
    $choice = Get-OvnPythonChoice
    $why = Get-OvnPythonVerdict $choice.Pick
    if ($choice.Pick -and -not $why) { Write-OvnPythonOk $choice.Pick $choice.Source; return }
    if ($choice.Pick) { Write-OvnNote "Overnight would pick $($choice.Pick.Exe) ($($choice.Source)), but $why." }
    else { Write-OvnNote 'No Python was found where Overnight looks.' }
    $usable = Get-OvnUsablePython $choice
    if ($usable) {
        Add-OvnProblem "Overnight would pick an unusable Python ($($choice.Pick.Exe)). A usable one is already here: $($usable.Exe)" "After the Skool login, open Settings > Tool paths > Python in Overnight and choose $($usable.Exe)"
        return
    }
    if ($Kit.Dry) { Write-OvnNote 'A real run would add Python 3.12 for this user next to anything already there (winget first, then python.org).'; return }
    $res = Install-OvnWithWinget 'Python.Python.3.12' 'Python 3.12' -UserScope
    Update-OvnSessionPath
    $choice = Get-OvnPythonChoice
    if ($res -ne 'ok' -and -not (Get-OvnUsablePython $choice)) {
        $res = Invoke-OvnThirdParty -Label 'Python 3.12' -Url 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe' `
            -File (Join-Path $Kit.Folder 'python-3.12.10-amd64.exe') `
            -Arguments '/quiet InstallAllUsers=0 PrependPath=1 Include_test=0 Include_launcher=0 InstallLauncherAllUsers=0' -OkCodes @(0, 3010)
        Update-OvnSessionPath
        $choice = Get-OvnPythonChoice
    }
    $why = Get-OvnPythonVerdict $choice.Pick
    $usable = Get-OvnUsablePython $choice
    if (-not @($choice.All | Where-Object { $_.Ran }).Count) {
        Add-OvnProblem 'Python does not start yet.' 'Open a new PowerShell window and run the same command again. If this happens again, restart the PC and run it once more.'
        return
    }
    if ($choice.Pick -and -not $why) { Write-OvnPythonOk $choice.Pick $choice.Source; return }
    if ($usable) {
        Add-OvnProblem "Overnight would still pick $($choice.Pick.Exe), and $why." "After the Skool login, open Settings > Tool paths > Python in Overnight and choose $($usable.Exe)"
        return
    }
    Add-OvnProblem 'No usable Python 3.12 could be added (the lines above say why).' 'Check the internet connection, then run the same command again.'
}

function Test-OvnVcRuntime {
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64')) {
        try { if ((Get-ItemProperty -Path $k -Name Installed -ErrorAction Stop).Installed -eq 1) { return $true } } catch { }
    }
    return $false
}

function Invoke-OvnVcStep {
    Write-OvnStep 'Microsoft Visual C++ runtime (needed for transcription)'
    if (Test-OvnVcRuntime) { Write-OvnOk 'The Visual C++ runtime (x64) is here.'; return }
    if ($Kit.Dry) { Write-OvnNote 'The Visual C++ runtime is missing. A real run would add it; Windows would ask for permission once.'; return }
    Write-OvnWarn 'Windows will now ask for permission (a User Account Control box) for the Microsoft Visual C++ runtime. Please click Yes.'
    $res = Install-OvnWithWinget 'Microsoft.VCRedist.2015+.x64' 'the Microsoft Visual C++ runtime'
    if (-not (Test-OvnVcRuntime)) {
        $res = Invoke-OvnThirdParty -Label 'the Microsoft Visual C++ runtime' -Url 'https://aka.ms/vs/17/release/vc_redist.x64.exe' `
            -File (Join-Path $Kit.Folder 'vc_redist.x64.exe') -Arguments '/install /quiet /norestart' -OkCodes @(0, 3010, 1638)
    }
    if (Test-OvnVcRuntime) { Write-OvnOk 'The Visual C++ runtime (x64) is here.'; return }
    Add-OvnProblem 'The Microsoft Visual C++ runtime is still missing. Overnight needs it for transcription.' 'Download https://aka.ms/vs/17/release/vc_redist.x64.exe, open it and click Yes in the Windows permission box, then run the same command again.'
}

function Invoke-OvnClaudeStep {
    Write-OvnStep 'Claude Code (Overnight runs your own Claude through it)'
    $args1 = @('--version')
    $found = Find-OvnTool (Get-OvnClaudeCandidates) $args1 '\d+\.\d+'
    if ($found) { Write-OvnOk "Claude Code is here: $($found.Path) ($($found.Version))"; Confirm-OvnOnPath $found.Path 'claude'; return }
    if ($Kit.Dry) { Write-OvnNote 'Claude Code is missing. A real run would run the official installer from claude.ai.'; return }
    $why = ''
    $file = Join-Path $Kit.Folder 'claude-install.ps1'
    Write-OvnBegin Download 'the Claude Code installer from claude.ai'
    if (-not (Save-OvnFile 'https://claude.ai/install.ps1' $file)) {
        $why = "claude.ai could not be reached ($($Kit.WebError))"
    } else {
        [void]$Kit.Downloads.Add($file)
        $text = [System.IO.File]::ReadAllText($file)
        if (Test-OvnLooksLikeHtml $text) {
            $why = 'a web page came back instead of the installer (a Wi-Fi login page or a web filter is in the way)'
        } else {
            Write-OvnBegin Install 'Claude Code'
            $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $r = Invoke-OvnProgram $ps @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file) 900
            foreach ($l in @($r.Lines)) {
                $clean = ($l -replace "\x1b\[[0-9;?]*[A-Za-z]", '').Trim()
                if ($clean) { Write-OvnNote "claude: $clean" }
            }
            if (-not $r.Started) { $why = "its installer did not start ($($r.Error))" }
            elseif ($r.TimedOut) { $why = 'its installer was still busy after 15 minutes' }
            elseif ($r.Code -ne 0) { $why = "its installer ended with code $(Format-OvnCode $r.Code)" }
        }
    }
    Update-OvnSessionPath
    $found = Find-OvnTool (Get-OvnClaudeCandidates) $args1 '\d+\.\d+'
    if ($found) { Write-OvnOk "Claude Code is here: $($found.Path) ($($found.Version))"; Confirm-OvnOnPath $found.Path 'claude'; return }
    if (-not $why) { $why = 'it cannot be found after its installer ran' }
    Write-OvnWarn "Claude Code is not set up: $why."
    Write-OvnWarn 'Overnight uses its own built-in copy meanwhile. Run the same command again once https://claude.ai opens in your browser.'
}

function Test-OvnLooksBlocked([string]$Text) {
    return ("$Text" -match '(?i)application control|smart app control|4551|block')
}

function Get-OvnSmartAppControl {
    try { return (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name VerifiedAndReputablePolicyState -ErrorAction Stop).VerifiedAndReputablePolicyState } catch { return $null }
}

# Runs Overnight's installer, or with a test release its fake-installer.ps1. Returns Started / TimedOut / Code / Error.
function Invoke-OvnSetupProgram([string]$File, [string]$Dir, [bool]$UseDir) {
    if ($Kit.TestBase -and ([System.IO.Path]::GetFileName($File) -like '*Overnight-Setup*')) {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $fake = [System.IO.Path]::Combine($Kit.TestBase, 'fake-installer.ps1')
        $line = Join-OvnArguments @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $fake, '-Setup', $File, '-Dir', $Dir)
        return (Start-OvnInstaller $ps $line 15 -NoShell)
    }
    $arguments = '/S'
    if ($UseDir) { $arguments = "/S /D=$Dir" }
    return (Start-OvnInstaller $File $arguments 15)
}

function Invoke-OvnAppStep {
    Write-OvnStep 'Overnight'

    # 1-2. Where it is, and an update an earlier run left half done.
    $dir = Get-OvnInstallFolder
    if (-not $Kit.Dry) { Recover-Aside $dir 'Overnight.exe' }

    # 3. What is installed, and what is newest.
    $app = Find-OvnApp
    $Kit.App = $app
    if ($app) { Write-OvnNote "Installed now: Overnight $($app.Version) in $($app.Dir)" } else { Write-OvnNote 'Overnight is not on this PC yet.' }
    $feedText = Get-OvnReleaseText 'latest.yml' ''
    $feed = $null
    if ($feedText) { $feed = Read-OvnFeed $feedText }
    $feedOk = [bool]($feed -and $feed.Version -and $feed.Installer)

    # 4. Is the installed copy whole?
    $broken = $false
    if ($app -and $app.Version) {
        $before = Test-OvnInstalledFiles $app.Dir $app.Version
        if (-not $before.HasList) {
            Write-OvnNote "No file list was found for Overnight $($app.Version), so its files could not be checked before installing."
        } elseif ($before.Complete) {
            Write-OvnOk "Overnight $($app.Version) has all $($before.Total) of its files."
        } else {
            $broken = $true
            if ($feedOk) { Write-OvnWarn "Overnight $($app.Version) is missing files ($($before.Line)). It will be installed again; your videos, settings and Skool login stay." }
            else { Write-OvnWarn "Overnight $($app.Version) is missing files ($($before.Line))." }
        }
    }

    if (-not $feedOk) {
        if (-not $app) {
            Stop-OvnSetup 'The newest Overnight release could not be read from github.com, so nothing of Overnight was changed.' 'This PC seems to be offline, or github.com is blocked. Check that github.com opens in your browser, then run the same command again.'
        }
        if ($broken) {
            Add-OvnProblem "Overnight $($app.Version) is missing files and could not be installed again: the newest release could not be read from github.com." 'Check that github.com opens in your browser, then run the same command again.'
            return
        }
        Add-OvnProblem "Could not check github.com for a newer Overnight, so it was not checked for an update. Overnight $($app.Version) stays as it is." 'Check that github.com opens in your browser, then run the same command again.'
        return
    }
    $target = $feed.Version
    Write-OvnNote "Newest release: Overnight $target"

    $root = $null
    if ($Kit.InstallDir.Trim() -and -not $Kit.TestBase) {
        $bad = $false
        try { $root = Resolve-OvnRoot $Kit.InstallDir } catch { $root = $null; $bad = $true }
        if ($bad -or -not $root) {
            Stop-OvnSetup "OVERNIGHT_INSTALL_DIR is not a usable folder: $($Kit.InstallDir)" 'Pick another folder, for example E:\Overnight, or leave OVERNIGHT_INSTALL_DIR out.'
        }
    }
    $hasSettings = Test-Path -LiteralPath (Join-Path $env:APPDATA 'Overnight\settings.json')
    $hasPointer = Test-Path -LiteralPath (Join-Path $env:APPDATA 'Overnight\data-location.json')
    $plan = Get-OvnDrivePlan -Root $root -Installed ([bool]$app) -Reinstall $Kit.Reinstall -HasSettings $hasSettings -HasPointer $hasPointer
    if ($plan.Ignored) { Write-OvnNote 'OVERNIGHT_INSTALL_DIR is left aside: Overnight is already installed. To move the app, also set OVERNIGHT_REINSTALL=1.' }
    $reinstall = $Kit.Reinstall -or $broken

    # 5. Decide.
    if ($app -and -not $reinstall -and (Compare-OvnVersion $app.Version $target) -ge 0) {
        Write-OvnOk "Overnight $($app.Version) is installed and up to date."
        return
    }
    $appDir = $dir
    if ($plan.UseRoot) { $appDir = $plan.AppDir }
    if ($Kit.Dry) {
        if ($app -and $broken) { Write-OvnNote "A real run would install Overnight $target again in $appDir, because the installed copy is missing files." }
        elseif ($app -and (Compare-OvnVersion $app.Version $target) -ge 0) { Write-OvnNote "A real run would put Overnight $target on again (OVERNIGHT_REINSTALL=1) in $appDir." }
        elseif ($app) { Write-OvnNote "A real run would update Overnight $($app.Version) to $target in $appDir." }
        else { Write-OvnNote "A real run would fetch Overnight $target, check its SHA-512 and SHA-256, and set it up in $appDir." }
        if ($plan.UseRoot) {
            $drive = [System.IO.Path]::GetPathRoot($root)
            if (-not (Test-Path -LiteralPath $drive)) { Add-OvnProblem "The drive $drive of OVERNIGHT_INSTALL_DIR does not exist." 'Pick another folder, or leave OVERNIGHT_INSTALL_DIR out.' }
            else { Write-OvnNote "A real run would first check that it can write in $root." }
            if ($plan.FirstInstall) { Write-OvnNote "A real run would keep Overnight's data in $($plan.DataDir) and new videos in $($plan.VideosDir)." }
            else { Write-OvnNote "Overnight's data would stay where it is now." }
        }
    }

    # 6. Is it open?
    if ($app) {
        $running = @(Get-OvnAppProcesses $app.Dir)
        if ($running.Count) {
            if (-not $Kit.CloseApp) {
                Add-OvnProblem "Overnight is open, so it was not updated to $target." 'Close Overnight and run the same command again. Overnight also updates itself when you close it.'
                return
            }
            if ($Kit.Dry) {
                Write-OvnNote 'Overnight is open. A real run would close it first (OVERNIGHT_CLOSE_APP=1), with everything running from its folder.'
            } else {
                Write-OvnNote 'Closing Overnight and everything running from its folder (allowed with OVERNIGHT_CLOSE_APP=1).'
                $left = Close-OvnAppProcesses $app.Dir 15
                if ($left) {
                    Add-OvnProblem "Overnight did not close, so it was not updated to $target." 'Close Overnight yourself (or restart the PC), then run the same command again.'
                    return
                }
                Write-OvnOk 'Overnight is closed.'
                Wait-OvnAppUpdater 180
                $again = Find-OvnApp
                if ($again -and -not $reinstall -and (Compare-OvnVersion $again.Version $target) -ge 0) {
                    $Kit.App = $again
                    Write-OvnOk "Overnight updated itself to $($again.Version) as it closed. It is up to date."
                    return
                }
            }
        }
    }
    if ($Kit.Dry) { return }

    # 7. Room on the drives, before anything is fetched or moved.
    $unpacked = Test-OvnSpace $target $appDir

    # 8. The installer, always saved under the name latest.yml gives.
    $name = $feed.Installer
    $file = Join-Path $Kit.Folder $name
    Write-OvnBegin Download "Overnight $target ($name)"
    if (-not (Save-OvnReleaseFile $name $target $file)) {
        Write-OvnWarn "The versioned installer could not be fetched ($($Kit.WebError)). Trying the copy under the stable name."
        if (-not (Save-OvnReleaseFile 'Overnight-Setup.exe' '' $file)) {
            Stop-OvnSetup "The Overnight installer could not be fetched ($($Kit.WebError)). Nothing was changed." 'Check the internet connection, then run the same command again.'
        }
    }
    [void]$Kit.Downloads.Add($file)

    # 9. SHA-512 from latest.yml, then the SHA-256 from the version's own SHA256SUMS.txt (always required).
    $h = Get-OvnFileHashes $file
    $sumsText = Get-OvnReleaseText 'SHA256SUMS.txt' $target
    $sums = $null
    if ($sumsText) { $sums = Read-OvnSums $sumsText }
    $verdict = Get-OvnHashVerdict -Actual512 $h.Sha512 -Actual256 $h.Sha256 -Feed512 $feed.Sha512 -Sums $sums -Name $name
    if (-not $verdict.Ok) {
        Remove-OvnFile $file
        if ($verdict.Why -eq 'sha512') {
            Stop-OvnSetup 'The download does not match the SHA-512 in latest.yml, so it was deleted and not run. Nothing was changed.' 'Antivirus web scanning or a proxy probably changed it. Pause HTTPS scanning or the VPN, or try another network, then run the same command again.'
        }
        if ($verdict.Why -eq 'no-sums') {
            Stop-OvnSetup "The download could not be checked: SHA256SUMS.txt of Overnight $target could not be read or has no line for $name. It was deleted and not run. Nothing was changed." 'Try again in a few minutes.'
        }
        Stop-OvnSetup "The download does not match the release's SHA-256 (SHA256SUMS.txt), so it was deleted and not run. Nothing was changed." 'Antivirus web scanning or a proxy probably changed it. Pause HTTPS scanning or the VPN, or allow github.com in the antivirus, then run the same command again.'
    }
    Write-OvnOk ("Checked: SHA-256 {0} matches SHA256SUMS.txt." -f $h.Sha256.ToUpperInvariant())

    # 10. Another drive: can the folder be written?
    if ($plan.UseRoot -and -not (Test-OvnWritable $root)) {
        Remove-OvnFile $file
        Stop-OvnSetup "Cannot create or write files in $root (OVERNIGHT_INSTALL_DIR)." 'Pick another folder, or leave OVERNIGHT_INSTALL_DIR out to use the normal place.'
    }

    # 11. Empty the install folder, so no installer has an old version to uninstall.
    $aside = $null
    $sameFolder = $true
    if ($app -and $plan.UseRoot) { $sameFolder = ((Get-OvnPathKey $plan.AppDir) -eq (Get-OvnPathKey $app.Dir)) }
    if ($app -and $sameFolder -and [System.IO.File]::Exists((Long-Path ([System.IO.Path]::Combine($app.Dir, 'Overnight.exe'))))) {
        $aside = Move-OldApp $app.Dir 'Overnight.exe'
        if (-not $aside) {
            $packs = [System.IO.Path]::Combine($app.Dir, 'resources\stylepacks')
            Remove-Tree $packs
            if ([System.IO.Directory]::Exists((Long-Path $packs))) { Write-OvnWarn 'Not all of the old style packs could be removed. If the installer stops with code 2, restart the PC and run the same command again.' }
            else { Write-OvnNote "The old style packs were removed; the installer replaces the rest in place." }
        }
    }

    # 12. The installer.
    Write-OvnNote 'The Overnight installer runs without a window. If an Overnight window asks something (not enough space, or a file in use), answer it.'
    Write-OvnBegin Install "Overnight $target into $appDir"
    $setupLog = Join-Path $env:TEMP ([System.IO.Path]::GetFileName($appDir.TrimEnd('\')) + '-update.log')
    $r = Invoke-OvnSetupProgram $file $appDir $plan.UseRoot
    if ($r.TimedOut) {
        Stop-OvnSetup 'The Overnight installer is still running after 15 minutes.' 'Look for an Overnight window that asks something (not enough space, or a file in use) and answer it. Then run the same command again: it finishes or undoes the update.'
    }
    if (-not $r.Started) {
        $back = $false
        if ($aside) { $back = Put-Back $aside $appDir 'Overnight.exe' }
        $backText = ''
        if ($back) { $backText = ' The version you had is back.' }
        if ((Get-OvnSmartAppControl) -eq 1 -or (Test-OvnLooksBlocked $r.Error)) {
            Stop-OvnSetup "Windows refused to start the Overnight installer, which is not code-signed yet ($($r.Error)).$backText" 'Smart App Control blocks unsigned programs. Turning it off is your decision (Windows Security > App & browser control > Smart App Control); on most Windows 11 versions it can only be turned on again by resetting Windows. You can first compare the installer with SHA256SUMS.txt on the release page.'
        }
        Stop-OvnSetup "The Overnight installer could not run: $($r.Error).$backText" 'Run the same command again. If it happens again, restart the PC first.'
    }
    if ($r.Code -ne 0) {
        Remove-OvnFile $file
        $back = $false
        if ($aside) { $back = Put-Back $aside $appDir 'Overnight.exe' }
        $backText = ''
        if ($back) { $backText = ' The version you had is back.' }
        if ($r.Code -eq 2) {
            Stop-OvnSetup "The Overnight installer stopped with code 2: Windows would not let its files be replaced, a program holds one of them, or the disk was too full.$backText" "Free some disk space, restart the PC and run the same command again. The installer's own log: $setupLog"
        }
        Stop-OvnSetup "The Overnight installer stopped with code $(Format-OvnCode $r.Code).$backText" "Your antivirus may have quarantined part of it: restore it and allow Overnight. The installer's own log is $setupLog. Then run the same command again."
    }

    # 13. First install on another drive: the data pointer and the folder for new videos.
    if ($plan.UseRoot -and $plan.FirstInstall) { Write-OvnFirstInstallData $plan }
    elseif ($plan.UseRoot) { Write-OvnNote 'Your data stays where it is. To move it, use Settings > General > Data folder > Move in Overnight. Videos already made stay where they are.' }

    # 14. Find it again.
    $new = Find-OvnApp
    if (-not $new) {
        Remove-OvnFile $file
        $backText = ''
        if ($aside -and (Put-Back $aside $appDir 'Overnight.exe')) { $backText = ' The version you had is back.' }
        Stop-OvnSetup "The installer finished, but Overnight.exe is not there.$backText" "Your antivirus probably quarantined it: restore Overnight from quarantine and allow it, then run the same command again. The installer's own log is $setupLog."
    }

    # 15. Are all its files there? If not: remove the program folder, install once more, check again.
    $after = Test-OvnInstalledFiles $new.Dir $new.Version
    if ($after.HasList -and -not $after.Complete) {
        Write-OvnWarn "Overnight $($new.Version) was installed, but the install is missing files ($($after.Line)). The program folder is removed and the installer runs once more."
        Remove-OvnProgramFolder $new.Dir
        Write-OvnBegin Install "Overnight $target into $appDir, second time"
        $r2 = Invoke-OvnSetupProgram $file $appDir $plan.UseRoot
        if (-not $r2.Started) { Write-OvnWarn "The second run of the installer did not start: $($r2.Error)" }
        elseif ($r2.TimedOut) { Write-OvnWarn 'The second run of the installer was still busy after 15 minutes.' }
        elseif ($r2.Code -ne 0) { Write-OvnWarn "The second run of the installer stopped with code $(Format-OvnCode $r2.Code)." }
        $again = Find-OvnApp
        if ($again) { $new = $again; $after = Test-OvnInstalledFiles $new.Dir $new.Version }
        else { $after = @{ HasList = $true; Complete = $false; Total = 0; Line = 'Overnight.exe is missing' } }
        if ($after.HasList -and -not $after.Complete) {
            $backText = ''
            if ($aside -and -not $broken -and $app -and (Compare-OvnVersion $target $app.Version) -gt 0) {
                if (Put-Back $aside $appDir 'Overnight.exe') {
                    Write-OvnNote "The version you had ($($app.Version)) is back."
                    $backText = " The version you had ($($app.Version)) is back and still works."
                }
            }
            Remove-OvnFile $file
            Stop-OvnSetup "Overnight $target is still missing files after installing it twice ($($after.Line)).$backText" ("Free some disk space (the app needs about {0} GB), restart the PC and run the same command again. If your antivirus removed files, restore them and allow Overnight's folder there." -f (Format-OvnNumber $unpacked))
        }
    }
    if ($after.HasList) { Write-OvnOk "Checked after installing: all $($after.Total) of Overnight's files are there." }
    else { Write-OvnNote "No file list was found for Overnight $($new.Version), so nothing could be checked." }

    # 16. Clean up: the download, then the aside folder.
    Remove-OvnFile $file
    if ($aside) {
        try { [System.IO.File]::Delete((Long-Path ([System.IO.Path]::Combine($aside, '.ovn-moved')))) } catch { }
        Remove-Tree $aside
        if ([System.IO.Directory]::Exists((Long-Path $aside))) { Write-OvnNote "The previous version's folder is left for the next update to remove: $aside" }
        else { Write-OvnNote "The previous version's folder was removed." }
    }

    $Kit.App = $new
    if ((Compare-OvnVersion $new.Version $target) -ne 0) {
        Add-OvnProblem "Overnight $($new.Version) is in $($new.Dir), but $target was expected." 'Restart the PC, then run the same command again.'
        return
    }
    if ($app) { Write-OvnOk "Overnight $($new.Version) is installed in $($new.Dir) (it was $($app.Version))." }
    else { Write-OvnOk "Overnight $($new.Version) is installed in $($new.Dir)." }
    if ($app -and $plan.UseRoot -and -not $sameFolder) { Write-OvnNote "The old app folder $($app.Dir) was left as it was." }
}

function Invoke-OvnFinishStep {
    Write-OvnStep 'Finish'
    $app = $Kit.App
    if ($app) {
        if (@(Get-OvnAppProcesses $app.Dir).Count) { Write-OvnOk 'Overnight is open.' }
        elseif ($Kit.NoOpen) { Write-OvnNote 'Overnight is not started here (OVERNIGHT_NO_OPEN=1).' }
        elseif ($Kit.Dry) { Write-OvnNote 'A real run would start Overnight now.' }
        else {
            try { Start-Process -FilePath $app.Exe -WorkingDirectory $app.Dir; Write-OvnOk 'Overnight is starting. Later, open it from the Start menu.' }
            catch { Add-OvnProblem "Overnight could not be started: $($_.Exception.Message)" 'Open Overnight from the Start menu. If its window stays dark, use the Start menu entry "Overnight (safe display)".' }
        }
    } elseif ($Kit.Dry -and -not $Kit.NoOpen) {
        Write-OvnNote 'A real run would start Overnight once it is installed.'
    }
    $videos = $Kit.VideosDir
    if (-not $videos) { $videos = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Overnight' }
    Write-OvnOut ''
    Write-OvnOut 'Next, in Overnight (only you can do these):'
    Write-OvnOut '  1. In the first window, log in with Skool, with the account you joined the community with:'
    Write-OvnOut "     $($Kit.Community)"
    Write-OvnOut '  2. On the Home page, press Sign in to connect your own Claude account.'
    Write-OvnOut '  3. On the Home page, under Install your tools, press Set up. It takes 10 to 30 minutes.'
    Write-OvnOut "Your videos are saved in $videos, unless you pick another folder in Overnight."
    Write-OvnOut 'Run the same command again at any time to update or repair Overnight.'
    Write-OvnOut ''
}

function Write-OvnSummary {
    if ($Kit.Dry) {
        if ($Kit.Later.Count) { Write-OvnOut ("A real run would leave {0} thing(s) for you, marked [note] above." -f $Kit.Later.Count) 'Yellow' }
        Write-OvnOut 'Test mode finished: nothing was changed.' 'Green'
        return 0
    }
    if ($Kit.Problems.Count) {
        Write-OvnOut ("Finished with {0} problem(s) left:" -f $Kit.Problems.Count) 'Red'
        $i = 0
        foreach ($p in $Kit.Problems) {
            $i++
            Write-OvnOut ("  {0}. {1}" -f $i, $p.Text) 'Red'
            if ($p.Fix) { Write-OvnOut ("     What to do: {0}" -f $p.Fix) 'Red' }
        }
        return 3
    }
    Write-OvnOut 'All set. Overnight is installed and ready.' 'Green'
    return 0
}

function Invoke-OvnSetup {
    try {
        Read-OvnSwitches
        Initialize-OvnNetwork
        Write-OvnIntro
        Initialize-OvnTestRelease
        Invoke-OvnComputerStep
        Invoke-OvnRedirectStep
        Invoke-OvnSpaceStep
        if ($Kit.TestBase) {
            Write-OvnStep 'Tools'
            Write-OvnWarn 'A test release is in use (OVERNIGHT_TEST_RELEASE_BASE): winget, git, ffmpeg, Python, the Visual C++ runtime and Claude Code are skipped.'
        } else {
            Invoke-OvnWingetStep
            Invoke-OvnGitStep
            Invoke-OvnFfmpegStep
            Invoke-OvnPythonStep
            Invoke-OvnVcStep
            Invoke-OvnClaudeStep
        }
        Invoke-OvnAppStep
        Invoke-OvnFinishStep
        return (Write-OvnSummary)
    } catch {
        Write-OvnOut ''
        if ($Kit.Stopped) {
            Write-OvnOut ('   [STOP] ' + $Kit.StopReason) 'Red'
            if ($Kit.StopFix) { Write-OvnOut ('          What to do: ' + $Kit.StopFix) 'Red' }
        } else {
            $line = $_.InvocationInfo.ScriptLineNumber
            Write-OvnOut ("   [STOP] Something unexpected went wrong: {0} (line {1})" -f $_.Exception.Message, $line) 'Red'
            Write-OvnOut ("          What to do: run the same command again. If it repeats, ask in the Overnight community and include the log.") 'Red'
        }
        Write-OvnOut ('Setup stopped. Nothing after this point ran. Log: ' + $Kit.Log) 'Red'
        return 1
    } finally {
        Remove-OvnDownloads
    }
}

$Kit = New-OvnState
$code = @(Invoke-OvnSetup)[-1]
$global:LASTEXITCODE = [int]$code
}
# Run as a file, pass the exit code on. Run through "irm ... | iex", leave the member's window open.
if (([scriptblock]{}).File) { exit $global:LASTEXITCODE }
