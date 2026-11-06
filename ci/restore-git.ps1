# CI only: puts back the runner's Git that ci/hide-tools.ps1 moved aside (the checkout's clean-up runs git), unless
# install.ps1 already installed a Git there.
if ((Test-Path -LiteralPath 'C:\Program Files\Git.hidden') -and -not (Test-Path -LiteralPath 'C:\Program Files\Git\cmd\git.exe')) {
  if (Test-Path -LiteralPath 'C:\Program Files\Git') { Remove-Item -LiteralPath 'C:\Program Files\Git' -Recurse -Force }
  Rename-Item -LiteralPath 'C:\Program Files\Git.hidden' -NewName 'Git'; 'restored C:\Program Files\Git'
} else { 'C:\Program Files\Git is in place' }
