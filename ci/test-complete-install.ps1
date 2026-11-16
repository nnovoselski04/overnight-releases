# install.ps1's complete-install steps (16 Nov 2026), run as a whole on a FAKE release in a scratch folder: nothing is
# downloaded, no real installer runs, the real Overnight is never touched. The fake release has latest.yml, the
# "installer" (random bytes), SHA256SUMS.txt, the lists of files (install-manifest-<version>.json) and fake-installer.ps1,
# which copies a payload into the install folder, leaving files out when asked. install.ps1 runs with
# OVERNIGHT_TEST_RELEASE_BASE / OVERNIGHT_TEST_APPDIR (only its Overnight step) and its own %TEMP%.
# Proves: (a) a short disk stops it with the numbers, nothing changed; (b) a download that does not match SHA256SUMS.txt
# never runs; (c) the install is checked against its list (its own, or for 0.5.0 the one on the release page); (d) an
# incomplete install is removed (the program folder only: the data and videos folders stay) and installed once more,
# and reported plainly when it stays incomplete; and a broken 0.5.0 that is the newest version is installed again.
#   powershell -NoProfile -ExecutionPolicy Bypass -File ci\test-complete-install.ps1 [-Root D:\Temp\ovn-complete-install]
param([string]$Root = 'D:\Temp\ovn-complete-install')
$ErrorActionPreference = 'Stop'
if ($Root -match 'Programs\\overnight|Roaming\\Overnight') { throw "STOP: $Root is a real app's folder" }
$script = (Resolve-Path (Join-Path $PSScriptRoot '..\install.ps1')).Path
$fails = 0
function Check($ok, $what) { if ($ok) { Write-Host "PASS $what" -ForegroundColor Green } else { Write-Host "FAIL $what" -ForegroundColor Red; $script:fails++ } }
function Long($p) { '\\?\' + $p }
function Clear-Dir($p) { if (Test-Path -LiteralPath $p) { & cmd.exe /c rd /s /q "$(Long $p)" 2>&1 | Out-Null } }

$rel = Join-Path $Root 'release'; $app = Join-Path $Root 'app\overnight'; $data = Join-Path $Root 'data'; $vids = Join-Path $Root 'videos'; $tmp = Join-Path $Root 'tmp'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Put($f, $t) { [void][IO.Directory]::CreateDirectory((Split-Path $f)); [IO.File]::WriteAllText($f, $t, $utf8) }

# the payload of a version: Overnight.exe (a stand-in), version.txt (the fake app's version), resources with a deep path
function Payload($ver, [bool]$ownList) {
  $p = Join-Path $rel "payload-$ver"
  Clear-Dir $p
  Put (Join-Path $p 'Overnight.exe') "fake overnight $ver"
  Put (Join-Path $p 'version.txt') $ver
  Put (Join-Path $p 'resources\app.asar') ('A' * 5000)
  Put (Join-Path $p 'resources\templates\director\PLAYBOOK.md') '# playbook'
  Put (Join-Path $p 'resources\stylepacks\crayon\v1\remotion\node_modules\scheduler\package.json') '{"name":"scheduler"}'
  Put (Join-Path $p 'resources\stylepacks\crayon\v1\remotion\node_modules\scheduler\index.js') 'module.exports = 1;'
  $deep = Join-Path $p 'resources\stylepacks\crayon\v1\remotion\node_modules\.remotion\chrome-headless-shell'
  while ($deep.Length -lt 280) { $deep = Join-Path $deep ('d' * 30) }
  [void][IO.Directory]::CreateDirectory((Long $deep)); [IO.File]::WriteAllText((Long (Join-Path $deep 'gdocs_script.js')), '// deep', $utf8)
  # the list, in the app's format (src/main/installcheck.js): one entry per line
  $res = Join-Path $p 'resources'; $cut = (Long $res).Length + 1; $lines = New-Object System.Collections.ArrayList; $bytes = 0
  foreach ($f in ([IO.DirectoryInfo]::new((Long $res))).EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) { $r = $f.FullName.Substring($cut).Replace('\', '/'); [void]$lines.Add("[`"$r`",$($f.Length)]"); $bytes += $f.Length }
  $text = "{`"format`":1,`"version`":`"$ver`",`"platform`":`"win32`",`"count`":$($lines.Count),`"bytes`":$bytes,`"runtime`":[],`"files`":[`n" + ($lines -join ",`n") + "`n]}`n"
  Put (Join-Path $rel "install-manifest-$ver.json") $text
  if ($ownList) { Put (Join-Path $res 'install-manifest.json') $text }
  return $p
}
# the fake installer: copies payload-<version of the setup> into -Dir; mode.txt: ok | partial-once | partial-always
$fake = @'
param([string]$Setup, [string]$Dir)
$rel = Split-Path $MyInvocation.MyCommand.Path
$ver = [regex]::Match([IO.Path]::GetFileName($Setup), 'Overnight-Setup-(.+)\.exe').Groups[1].Value
Add-Content -LiteralPath (Join-Path $rel 'runs.txt') -Value $ver
$mode = ([IO.File]::ReadAllText((Join-Path $rel 'mode.txt'))).Trim()
& robocopy.exe (Join-Path $rel "payload-$ver") $Dir /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($mode -eq 'partial-always' -or $mode -eq 'partial-once') {
  Remove-Item -LiteralPath (Join-Path $Dir 'resources\templates\director\PLAYBOOK.md') -Force
  Remove-Item -LiteralPath (Join-Path $Dir 'resources\stylepacks\crayon\v1\remotion\node_modules\scheduler') -Recurse -Force
  if ($mode -eq 'partial-once') { [IO.File]::WriteAllText((Join-Path $rel 'mode.txt'), 'ok') }
}
exit 0
'@
function Release($latestVer, [switch]$BadSha, $mode = 'ok') {
  Clear-Dir $rel
  [void][IO.Directory]::CreateDirectory($rel)
  [void](Payload '0.5.0' $false)
  [void](Payload '0.5.1' $true)
  foreach ($v in '0.5.0', '0.5.1') { $b = New-Object byte[] 200000; (New-Object Random ([int]($v -replace '\D', ''))).NextBytes($b); [IO.File]::WriteAllBytes((Join-Path $rel "Overnight-Setup-$v.exe"), $b) }
  $setup = Join-Path $rel "Overnight-Setup-$latestVer.exe"
  $s512 = [Convert]::ToBase64String([Security.Cryptography.SHA512]::Create().ComputeHash([IO.File]::ReadAllBytes($setup)))
  Put (Join-Path $rel 'latest.yml') "version: $latestVer`nfiles:`n  - url: Overnight-Setup-$latestVer.exe`npath: Overnight-Setup-$latestVer.exe`nsha512: $s512`n"
  $h = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash
  if ($BadSha) { $h = '0' * 64 }
  Put (Join-Path $rel 'SHA256SUMS.txt') "$h  Overnight-Setup-$latestVer.exe`n$h  Overnight-Setup.exe`n"
  Put (Join-Path $rel 'fake-installer.ps1') $fake
  Put (Join-Path $rel 'mode.txt') $mode
}
# the installed copy before the run: a version's payload, files left out when asked
function Installed($ver, [string[]]$drop = @()) {
  Clear-Dir (Split-Path $app); Clear-Dir "$app.ovn-old"
  & robocopy.exe (Join-Path $rel "payload-$ver") $app /E /NFL /NDL /NJH /NJS /NP | Out-Null
  foreach ($d in $drop) { Remove-Item -LiteralPath (Join-Path $app $d) -Recurse -Force }
}
function Run-Install($freeGB = '') {
  Clear-Dir $tmp; [void][IO.Directory]::CreateDirectory($tmp)
  Remove-Item -LiteralPath (Join-Path $rel 'runs.txt') -Force -ErrorAction SilentlyContinue
  $e = @{ OVERNIGHT_TEST_RELEASE_BASE = $rel; OVERNIGHT_TEST_APPDIR = $app; OVERNIGHT_NO_OPEN = '1'; OVERNIGHT_TEST_FREE_GB = $freeGB; TEMP = $tmp; TMP = $tmp }
  $old = @{}; foreach ($k in $e.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $(if ($e[$k]) { $e[$k] } else { $null })) }
  try { $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE }
  finally { foreach ($k in $old.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) } }
  $runs = if (Test-Path -LiteralPath (Join-Path $rel 'runs.txt')) { @(Get-Content -LiteralPath (Join-Path $rel 'runs.txt')) } else { @() }
  return @{ code = $code; out = ($out -join "`n"); runs = $runs }
}
function Has($r, $re) { return [bool]($r.out -match $re) }
function Show($r) { Write-Host ($r.out -split "`n" | Where-Object { $_ -match '\[ok\]|\[!\]|stopped|==> Overnight|Finished|All set' } | Select-Object -Last 14 | Out-String) -ForegroundColor DarkGray }

try {
  Clear-Dir $Root
  Put (Join-Path $data 'settings.json') '{"workspace":"videos"}'; Put (Join-Path $vids 'My video\project.json') '{}'
  $sentinels = @((Join-Path $data 'settings.json'), (Join-Path $vids 'My video\project.json'))

  Write-Host "`n== 1. a broken 0.5.0 (two files missing, no list of its own) while 0.5.0 is the newest: installed again, checked against the release's list"
  Release '0.5.0'; Installed '0.5.0' @('resources\templates\director\PLAYBOOK.md', 'resources\stylepacks\crayon\v1\remotion\node_modules\scheduler')
  $r = Run-Install; Show $r
  Check (Has $r 'Overnight 0\.5\.0 is missing files \(3 of 5 files missing') 'the broken install is found (the list from the release page)'
  Check ($r.runs.Count -eq 1 -and $r.code -eq 0) "installed again although it is the newest version (code $($r.code), runs $($r.runs.Count))"
  Check (Has $r "all 5 of Overnight's files are there") 'checked after the install: complete'
  Check (Test-Path -LiteralPath (Join-Path $app 'resources\templates\director\PLAYBOOK.md')) 'the missing file is back'
  Check (-not (Test-Path -LiteralPath "$app.ovn-old")) 'the broken copy that was moved aside is gone'

  Write-Host "`n== 2. the same broken 0.5.0, 0.5.1 out: updated, checked against 0.5.1's own list"
  Release '0.5.1'; Installed '0.5.0' @('resources\templates\director\PLAYBOOK.md')
  $r = Run-Install; Show $r
  Check ($r.code -eq 0 -and $r.runs -contains '0.5.1' -and (Has $r "all 5 of Overnight's files are there")) "updated and complete (code $($r.code))"

  Write-Host "`n== 3. (a) a short disk: stopped with the numbers, nothing changed"
  Release '0.5.1'; Installed '0.5.0' @('resources\templates\director\PLAYBOOK.md')
  $before = @(Get-ChildItem -LiteralPath $app -Recurse -Force).Count
  $r = Run-Install '0.9'; Show $r
  Check ($r.code -eq 1 -and (Has $r 'not enough free disk space to install Overnight: [A-Z]: has 0\.9 GB free and the install needs about [\d.]+ GB while it runs\. Free [\d.]+ GB or more')) "refused with the numbers (code $($r.code))"
  Check ($r.runs.Count -eq 0 -and @(Get-ChildItem -LiteralPath $app -Recurse -Force).Count -eq $before -and -not (Test-Path -LiteralPath "$app.ovn-old")) 'nothing was run, moved or changed'

  Write-Host "`n== 4. (b) a download that does not match SHA256SUMS.txt: never run"
  Release '0.5.1' -BadSha; Installed '0.5.0'
  $r = Run-Install; Show $r
  Check ($r.code -eq 1 -and (Has $r "does not match the release's SHA-256") -and $r.runs.Count -eq 0) "refused, never run (code $($r.code))"
  Check ((Get-Content -LiteralPath (Join-Path $app 'version.txt')) -eq '0.5.0' -and -not (Test-Path -LiteralPath "$app.ovn-old")) 'the installed version is untouched'

  Write-Host "`n== 5. (c)(d) the install leaves files out once: the program folder is removed and installed again"
  Release '0.5.1' -mode 'partial-once'; Installed '0.5.0'
  $r = Run-Install; Show $r
  Check (Has $r 'the install is missing files \(3 of 5 files missing') 'the incomplete install is found'
  Check ($r.runs.Count -eq 2 -and $r.code -eq 0 -and (Has $r "all 5 of Overnight's files are there")) "installed once more, complete (code $($r.code), runs $($r.runs.Count))"
  Check (@($sentinels | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 2) 'the data and videos folders are untouched'

  Write-Host "`n== 6. (d) it stays incomplete: said plainly, the version you had back"
  Release '0.5.1' -mode 'partial-always'; Installed '0.5.0'
  $r = Run-Install; Show $r
  Check ($r.code -eq 1 -and $r.runs.Count -eq 2 -and (Has $r 'Overnight 0\.5\.1 is still missing files after installing it twice \(3 of 5 files missing')) "reported plainly after two tries (code $($r.code))"
  Check ((Has $r 'The version you had \(0\.5\.0\) is back') -and (Get-Content -LiteralPath (Join-Path $app 'version.txt')) -eq '0.5.0') 'the complete 0.5.0 it had is back'
  Check (@($sentinels | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 2) 'the data and videos folders are untouched'

  Write-Host "`n== 7. a complete install of the newest version: checked, nothing installed"
  Release '0.5.1'; Installed '0.5.1'
  $r = Run-Install; Show $r
  Check ($r.code -eq 0 -and $r.runs.Count -eq 0 -and (Has $r 'Overnight 0\.5\.1 has all 5 of its files') -and (Has $r 'is installed and up to date')) "left as it is (code $($r.code))"
} finally {
  Clear-Dir $Root
}
Write-Host ''
if ($fails) { Write-Host "$fails check(s) FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'all passed' -ForegroundColor Green; exit 0 }
