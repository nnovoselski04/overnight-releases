# CI only: puts back the runner's Git that ci/hide-tools.ps1 moved aside (the checkout's clean-up runs git).
if (Test-Path -LiteralPath 'C:\Program Files\Git.hidden') { Rename-Item -LiteralPath 'C:\Program Files\Git.hidden' -NewName 'Git'; 'restored C:\Program Files\Git' }
