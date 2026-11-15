# install.ps1's update steps (Move-OldApp, Put-Back, Recover-Aside) for real, on the PROBE app that the app repo's
# tools/test_install_update.mjs builds ("Overnight Probe": its own appId, GUID and folders; the real Overnight is never
# touched). It runs the probe's stock installers (what 0.4.9 and older ship), the way install.ps1 runs Overnight's.
#   node tools/test_install_update.mjs --only=none --keep     (in the app repo: builds the probe installers)
#   powershell -NoProfile -ExecutionPolicy Bypass -File ci\test-move-aside.ps1 [-Root D:\Temp\ovn-probe]
param([string]$Root = 'D:\Temp\ovn-probe')
$ErrorActionPreference = 'Stop'
$exeName = 'Overnight Probe.exe'
$dir = Join-Path $Root 'inst-ps1\ovnprobe'
if ($dir -match 'Programs\\Overnight|Programs\\ovnqatest|Roaming\\Overnight') { throw "STOP: $dir is a real app's folder" }
$old = Get-ChildItem -Path (Join-Path $Root 'out-old-*\ovnprobe-Setup-1.0.0.exe') | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$new = Get-ChildItem -Path (Join-Path $Root 'out-old2-*\ovnprobe-Setup-1.0.1.exe') | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $old -or -not $new) { throw "the probe installers are not built in $Root (run tools/test_install_update.mjs in the app repo first)" }

# the functions, taken from install.ps1 itself (its AST), with the output helpers they call
$src = Join-Path $PSScriptRoot '..\install.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $src), [ref]$null, [ref]$null)
$want = 'Long-Path', 'Remove-Tree', 'App-Only', 'Folder-Procs', 'Recover-Aside', 'Move-OldApp', 'Put-Back', 'Invoke-Native'
foreach ($f in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { if ($want -contains $f.Name) { . ([scriptblock]::Create($f.Extent.Text)) } }
function Note($t) { Write-Host "    $t" -ForegroundColor DarkGray }
function Warn($t) { Write-Host "    [!] $t" -ForegroundColor Yellow }
function Stop-Install($t) { Write-Host "    stop: $t" -ForegroundColor Red; throw 'OVN_STOP' }

$fails = 0
function Check($ok, $what) { if ($ok) { Write-Host "PASS $what" -ForegroundColor Green } else { Write-Host "FAIL $what" -ForegroundColor Red; $script:fails++ } }
function Ver($d) { $f = Join-Path $d $exeName; if (-not (Test-Path -LiteralPath $f)) { return $null }; $v = (Get-Item -LiteralPath $f).VersionInfo.ProductVersion; if ($v -match '^\d+\.\d+\.\d+\.\d+$') { $v -replace '\.\d+$', '' } else { $v } }
function Install($setup, [string[]]$a) { $p = Start-Process -FilePath $setup -ArgumentList $a -PassThru; $null = $p.Handle; [void]$p.WaitForExit(600000); $p.ExitCode }
function Over260($d) { $p = Join-Path $d 'resources\over260'; while ($p.Length -lt 300) { $p = Join-Path $p ('q' * 30) }; [void][IO.Directory]::CreateDirectory((Long-Path $p)); [IO.File]::WriteAllText((Long-Path (Join-Path $p 'x.txt')), 'x') }
function Clean {
  foreach ($d in @($dir, "$dir.ovn-old")) {
    $u = Join-Path $d 'Uninstall Overnight Probe.exe'
    if (Test-Path -LiteralPath $u) { $p = Start-Process -FilePath $u -ArgumentList '/S', "_?=$d" -PassThru; [void]$p.WaitForExit(120000) }
    Remove-Tree $d
  }
  Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' | Where-Object { (Get-ItemProperty -LiteralPath $_.PSPath -EA SilentlyContinue).DisplayName -eq 'Overnight Probe' } | ForEach-Object { Remove-Item -LiteralPath ('HKCU:\Software\' + $_.PSChildName) -Recurse -Force -EA SilentlyContinue; Remove-Item -LiteralPath $_.PSPath -Recurse -Force -EA SilentlyContinue }
  Remove-Item -LiteralPath (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Overnight Probe.lnk') -Force -EA SilentlyContinue
}

# the stock installer's "Failed to uninstall" box shows even in a silent run: the probe tool's watcher reads and closes it
$run = Join-Path $Root 'run'; New-Item -ItemType Directory -Force -Path $run | Out-Null
$dlg = Join-Path $run 'ps1-dialogs.log'; $stop = Join-Path $run 'ps1-watch.stop'
Remove-Item -LiteralPath $dlg, $stop -Force -EA SilentlyContinue
$watch = Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'watch.ps1'), $dlg, $stop -WindowStyle Hidden -PassThru
try {
  # 1. the update install.ps1 makes with a stock installer, over an install with a path already over 260
  Clean
  Check ((Install $old.FullName @('/S', "/D=$dir")) -eq 0) 'stock 1.0.0 installed'
  Over260 $dir
  $code = Install $new.FullName @('/S')
  $said = (Get-Content -LiteralPath $dlg -EA SilentlyContinue) -join ' '
  Check ($code -eq 2 -and (Ver $dir) -eq '1.0.0' -and $said -match 'Failed to uninstall old application files') "without the move aside the stock installer stops with code 2 (got $code, still $(Ver $dir), box: $said): install.ps1's 'did not finish (code 2)'"
  Clean
  [void](Install $old.FullName @('/S', "/D=$dir")); Over260 $dir
  $aside = Move-OldApp $dir $exeName
  Check ($aside -and (Test-Path -LiteralPath (Join-Path $aside '.ovn-moved')) -and -not (Test-Path -LiteralPath $dir)) 'Move-OldApp moved it aside in one rename, marked'
  $code = Install $new.FullName @('/S')
  Check ($code -eq 0 -and (Ver $dir) -eq '1.0.1') "then the same stock installer works (code $code, now $(Ver $dir))"
  Remove-Item -LiteralPath (Join-Path $aside '.ovn-moved') -Force; Remove-Tree $aside
  Check (-not (Test-Path -LiteralPath $aside)) 'the old folder, path over 260 and all, is deleted'

  # 2. a file held open by another program: nothing changes, one plain line
  Clean
  [void](Install $old.FullName @('/S', "/D=$dir"))
  $h = [IO.File]::Open((Join-Path $dir 'resources\app.asar'), 'Open', 'Read', 'Read')
  $msg = $null; try { [void](Move-OldApp $dir $exeName) } catch { $msg = "$_" }
  $h.Close()
  Check ($msg -eq 'OVN_STOP' -and (Ver $dir) -eq '1.0.0' -and -not (Test-Path -LiteralPath "$dir.ovn-old")) 'a held file: the install stops, nothing moved, the old version is whole'

  # 3. an install that failed after the move: Put-Back
  $aside = Move-OldApp $dir $exeName
  New-Item -ItemType Directory -Force -Path $dir | Out-Null; Set-Content -LiteralPath (Join-Path $dir 'half.txt') -Value 'half'
  Check ((Put-Back $aside $dir $exeName) -and (Ver $dir) -eq '1.0.0' -and -not (Test-Path -LiteralPath (Join-Path $dir 'half.txt')) -and -not (Test-Path -LiteralPath (Join-Path $dir '.ovn-moved'))) 'Put-Back: the old version is back, the half install gone'

  # 4. a run that died after the move: the next run's Recover-Aside
  $aside = Move-OldApp $dir $exeName
  Recover-Aside $dir $exeName
  Check ((Ver $dir) -eq '1.0.0' -and -not (Test-Path -LiteralPath $aside)) 'Recover-Aside: a marked folder goes back'
  New-Item -ItemType Directory -Force -Path "$dir.ovn-old\resources" | Out-Null
  Recover-Aside $dir $exeName
  Check (-not (Test-Path -LiteralPath "$dir.ovn-old") -and (Ver $dir) -eq '1.0.0') 'Recover-Aside: an unmarked leftover is deleted, the install stays'

  # 5. a folder with the member's own files in it keeps the old route
  New-Item -ItemType Directory -Force -Path (Join-Path $dir 'videos') | Out-Null
  Check ($null -eq (Move-OldApp $dir $exeName) -and (Test-Path -LiteralPath (Join-Path $dir 'videos'))) 'a folder with other files is not moved (the old route)'
}
finally { Clean; Set-Content -LiteralPath $stop -Value ''; Start-Sleep -Seconds 1; try { $watch | Stop-Process -Force -EA SilentlyContinue } catch { } }
if ($fails) { Write-Host "$fails check(s) failed" -ForegroundColor Red; exit 1 } else { Write-Host 'all checks passed' -ForegroundColor Green; exit 0 }
