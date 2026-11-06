# CI only (an ephemeral GitHub runner): make the runner look like a member's fresh PC by hiding its own git, Python,
# ffmpeg and Claude Code from the registry PATH (which install.ps1 reads) and moving C:\Program Files\Git aside.
# ci/restore-git.ps1 puts Git back before the job's own clean-up needs it.
$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_ACTIONS) { throw 'ci/hide-tools.ps1 is for the GitHub runner only' }
$tools = 'git.exe', 'python.exe', 'ffmpeg.exe', 'claude.exe'
foreach ($scope in 'Machine', 'User') {
  $all = @([Environment]::GetEnvironmentVariable('Path', $scope) -split ';' | Where-Object { $_ })
  $keep = @()
  foreach ($d in $all) {
    $hasTool = $false
    if ($d -notlike '*\WindowsApps*') { foreach ($t in $tools) { if (Test-Path -LiteralPath (Join-Path $d $t)) { $hasTool = $true } } }
    if ($hasTool -or $d -match '\\Git\\|hostedtoolcache\\windows\\Python|\\Python3\d+') { "removed from the $scope PATH: $d" } else { $keep += $d }
  }
  [Environment]::SetEnvironmentVariable('Path', ($keep -join ';'), $scope)
}
if (Test-Path -LiteralPath 'C:\Program Files\Git') { Rename-Item -LiteralPath 'C:\Program Files\Git' -NewName 'Git.hidden'; 'moved C:\Program Files\Git aside' }
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
foreach ($t in 'git', 'python', 'ffmpeg', 'claude') {
  $c = Get-Command $t -All -CommandType Application -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
  "{0,-7} now: {1}" -f $t, $(if ($c) { $c -join ', ' } else { 'not found' })
}
