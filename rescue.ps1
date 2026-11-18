# Overnight rescue for Windows (rescue.ps1)
#
# For when Overnight is installed but its window stays black, dark or empty and Settings cannot be reached. It closes
# Overnight and starts it once without the graphics card (the --software-graphics start switch). The Start menu
# entry "Overnight (safe display)" does much the same; this script is for working from a command line.
#
# Run it from the web (it never closes your window):
#   irm https://raw.githubusercontent.com/nnovoselski04/overnight-releases/main/rescue.ps1 | iex
# or as a file:
#   powershell -NoProfile -ExecutionPolicy Bypass -File rescue.ps1
#
# Setting: OVERNIGHT_SETUP_DRY (any non-empty value) is test mode: it reports what it would close and start, and
# does neither.
#
# Exit codes:
#   0  Overnight was started without the graphics card (or test mode finished)
#   1  Overnight is not installed on this PC
#   2  Overnight could not be started, or it closed again right away (often because an old copy would not close)
#   3  this is not Windows, or something unexpected went wrong
#
# It changes no file, setting, registry value or PATH, and writes nothing. It only ends Overnight's processes (every
# process whose program lies inside Overnight's install folder) and starts Overnight once. Your videos, projects,
# settings and Skool login stay untouched. It never ends any other program.

& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-RescueOut([string]$Text, [string]$Color) {
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}
function Write-RescueStep([string]$Text) { Write-RescueOut ''; Write-RescueOut ('== ' + $Text) 'Cyan' }
function Write-RescueOk([string]$Text)   { Write-RescueOut ('   [ok]   ' + $Text) 'Green' }
function Write-RescueNote([string]$Text) { Write-RescueOut ('   [..]   ' + $Text) }
function Write-RescueWarn([string]$Text) { Write-RescueOut ('   [warn] ' + $Text) 'Yellow' }
function Write-RescueStop([string]$Text, [string]$Fix) {
    Write-RescueOut ('   [STOP] ' + $Text) 'Red'
    if ($Fix) { Write-RescueOut ('          What to do: ' + $Fix) 'Red' }
    Write-RescueOut 'Rescue stopped.' 'Red'
}

function Get-RescueUnquoted([string]$Value) {
    $v = "$Value".Trim()
    if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) { return $v.Substring(1, $v.Length - 2) }
    return $v
}

# Overnight's folder: the InstallLocation electron-builder keeps under HKCU\Software\<uninstall key name>, the
# uninstall entry's own InstallLocation, the folder of its uninstaller, then the default folder. This also finds an
# install on another drive.
function Find-RescueApp {
    $dirs = @()
    foreach ($key in @(Get-ChildItem -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue)) {
        $e = $null
        try { $e = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop } catch { continue }
        if ($e.DisplayName -ne 'Overnight') { continue }
        try {
            $own = Get-ItemProperty -LiteralPath ('HKCU:\Software\' + $key.PSChildName) -ErrorAction Stop
            if ($own.InstallLocation) { $dirs += (Get-RescueUnquoted $own.InstallLocation).TrimEnd('\') }
        } catch { }
        if ($e.InstallLocation) { $dirs += (Get-RescueUnquoted $e.InstallLocation).TrimEnd('\') }
        $u = "$($e.UninstallString)"
        $exe = $null
        if ($u -match '^\s*"([^"]+)"') { $exe = $Matches[1] } elseif ($u -match '^\s*(.+?\.exe)') { $exe = $Matches[1] }
        if ($exe) { try { $dirs += [System.IO.Path]::GetDirectoryName($exe) } catch { } }
    }
    $dirs += (Join-Path $env:LOCALAPPDATA 'Programs\overnight')
    foreach ($d in @($dirs | Where-Object { $_ })) {
        $exe = [System.IO.Path]::Combine($d, 'Overnight.exe')
        if (Test-Path -LiteralPath $exe -PathType Leaf) {
            $ver = ''
            try { $ver = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion } catch { }
            return @{ Exe = $exe; Dir = $d; Version = $ver }
        }
    }
    return $null
}

function Get-RescueProcesses([string]$Dir) {
    $prefix = $Dir.TrimEnd('\') + '\'
    return @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $p = $null
        try { $p = $_.Path } catch { }
        $p -and $p.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    })
}

# Asks Overnight's windows to close, then ends what is left running from its folder. Returns how many remain.
function Close-RescueProcesses([string]$Dir, [int]$Seconds) {
    foreach ($p in @(Get-RescueProcesses $Dir)) {
        try { if ($p.MainWindowHandle -ne [IntPtr]::Zero) { [void]$p.CloseMainWindow() } } catch { }
    }
    $start = Get-Date
    $forced = $false
    while (((Get-Date) - $start).TotalSeconds -lt $Seconds) {
        $left = @(Get-RescueProcesses $Dir)
        if (-not $left.Count) { return 0 }
        if (-not $forced -and ((Get-Date) - $start).TotalSeconds -ge 3) {
            foreach ($p in $left) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
            $forced = $true
        }
        Start-Sleep -Milliseconds 500
    }
    return @(Get-RescueProcesses $Dir).Count
}

# The app's log: under the folder named by its data pointer, or under %APPDATA%\Overnight.
function Get-RescueLogPath {
    $data = Join-Path $env:APPDATA 'Overnight'
    $ptr = Join-Path $data 'data-location.json'
    if (Test-Path -LiteralPath $ptr) {
        try {
            $j = [System.IO.File]::ReadAllText($ptr) | ConvertFrom-Json
            if ($j.dir -is [string] -and $j.dir.Trim()) { $data = $j.dir.Trim() }
        } catch { }
    }
    return [System.IO.Path]::Combine($data, 'logs\overnight.log')
}

function Get-RescueFileLength([string]$Path) {
    try { if (Test-Path -LiteralPath $Path) { return (Get-Item -LiteralPath $Path).Length } } catch { }
    return 0
}

# Reads what was added to a log after a given length, without blocking the app that writes it.
function Read-RescueLogTail([string]$Path, [long]$From) {
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($fs.Length -lt $From) { $From = 0 }
            [void]$fs.Seek($From, [System.IO.SeekOrigin]::Begin)
            $reader = New-Object System.IO.StreamReader($fs)
            return $reader.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return '' }
}

function Invoke-Rescue {
    $dry = -not [string]::IsNullOrEmpty($env:OVERNIGHT_SETUP_DRY)
    $oneLiner = 'irm https://raw.githubusercontent.com/nnovoselski04/overnight-releases/main/install.ps1 | iex'
    try {
        Write-RescueOut 'Overnight rescue: starts Overnight once without the graphics card.'
        Write-RescueOut 'Your videos, projects, settings and Skool login stay untouched.'
        if ($dry) { Write-RescueOut 'Test mode: nothing will be closed or started.' 'Yellow' }

        if ($env:OS -ne 'Windows_NT') {
            Write-RescueStop 'This rescue is for Windows only. A Mac has no rescue script.' 'Quit Overnight and open it again.'
            return 3
        }

        Write-RescueStep 'Finding Overnight'
        $app = Find-RescueApp
        if (-not $app) {
            Write-RescueStop 'Overnight is not installed on this PC.' "Set it up first: open PowerShell from the Start menu and paste: $oneLiner"
            return 1
        }
        Write-RescueOk "Overnight $($app.Version) in $($app.Dir)"

        Write-RescueStep 'Closing Overnight'
        $running = @(Get-RescueProcesses $app.Dir)
        if (-not $running.Count) { Write-RescueOk 'Overnight is not running.' }
        elseif ($dry) { Write-RescueNote ("Would close {0} process(es) running from Overnight's folder: {1}" -f $running.Count, (($running | ForEach-Object { $_.Id }) -join ', ')) }
        else {
            $left = Close-RescueProcesses $app.Dir 15
            if ($left) { Write-RescueWarn 'Overnight is still closing. If its window does not open in a moment, restart the PC and run the rescue again.' }
            else { Write-RescueOk 'Overnight is closed.' }
        }

        Write-RescueStep 'Starting Overnight without the graphics card'
        $log = Get-RescueLogPath
        if ($dry) {
            Write-RescueNote "Would start: `"$($app.Exe)`" --software-graphics"
            Write-RescueNote "Would then watch its log for the start line: $log"
            Write-RescueOut ''
            Write-RescueOut 'Test mode finished: nothing was changed.' 'Green'
            return 0
        }
        $before = Get-RescueFileLength $log
        try { $proc = Start-Process -FilePath $app.Exe -ArgumentList '--software-graphics' -WorkingDirectory $app.Dir -PassThru }
        catch {
            Write-RescueStop "Overnight could not be started: $($_.Exception.Message)" 'Restart the PC and run the rescue again. If it still fails, write a report as AGENTS.md describes, or ask in the Overnight community.'
            return 2
        }
        $seen = $null
        for ($i = 0; $i -lt 30 -and -not $seen; $i++) {
            Start-Sleep -Seconds 1
            $added = Read-RescueLogTail $log $before
            $hit = @(($added -split "`r?`n") | Where-Object { $_ -match '--- Overnight \S+ on win32' } | Select-Object -First 1)
            if ($hit.Count) { $seen = $hit[0] }
        }
        $alive = @(Get-RescueProcesses $app.Dir).Count
        if ($seen) { Write-RescueOk "Overnight started. Its log says: $($seen.Trim())" }
        elseif ($alive) { Write-RescueWarn "Overnight is running, but its log ($log) shows no new start line yet." }
        else {
            Write-RescueStop 'Overnight closed again right after it started.' 'Restart the PC and run the rescue again. If it still closes, write a report as AGENTS.md describes, or ask in the Overnight community.'
            return 2
        }

        Write-RescueOut ''
        Write-RescueOut 'This start is not saved. To keep it: when the window shows, open Settings > System > Graphics'
        Write-RescueOut 'in Overnight and pick "No graphics card" (called "Software" in 0.4.9 and older).'
        Write-RescueOut 'If the window is still blank, run the install command again to update; newer versions get past'
        Write-RescueOut "a graphics crash at start: $oneLiner"
        Write-RescueOut 'Next time, the Start menu entry "Overnight (safe display)" also starts it without the graphics card.'
        return 0
    } catch {
        Write-RescueStop ("Something unexpected went wrong: {0} (line {1})" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) 'Run the rescue again. If it repeats, ask in the Overnight community.'
        return 3
    }
}

$code = @(Invoke-Rescue)[-1]
$global:LASTEXITCODE = [int]$code
}
# Run as a file, pass the exit code on. Run through "irm ... | iex", leave the member's window open.
if (([scriptblock]{}).File) { exit $global:LASTEXITCODE }
