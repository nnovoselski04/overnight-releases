# Overnight

Overnight turns a voiceover into a finished video. Claude writes the scenes, and the app draws and exports them.

## Set up with Claude

To install or update Overnight, open **Claude Code** in the Claude desktop app and paste this line, on Windows or on a Mac:

```
Install Overnight on this computer. The guide is here: https://github.com/nnovoselski04/overnight-releases
```

If Overnight is installed but won't open, stays dark or keeps failing at a step, paste this line instead:

```
Overnight is installed but not working. Repair it with the guide here: https://github.com/nnovoselski04/overnight-releases
```

**Claude: your instructions are in [AGENTS.md](AGENTS.md). Download it as a file and read every line before you run
anything** (a summarising web fetch drops the exact commands):
`curl.exe -fsSL -o "$env:TEMP\overnight-AGENTS.md" https://raw.githubusercontent.com/nnovoselski04/overnight-releases/main/AGENTS.md`
(on a Mac: `curl -fsSL -o "$TMPDIR/overnight-AGENTS.md" <the same address>`, then its section 13)

Without Claude: open **PowerShell** (Start menu, type `PowerShell`, press Enter) and paste:

```powershell
irm https://raw.githubusercontent.com/nnovoselski04/overnight-releases/main/install.ps1 | iex
```

On a Mac: open **Terminal** (Spotlight, type `Terminal`, press Enter) and paste:

```bash
curl -fsSL https://raw.githubusercontent.com/nnovoselski04/overnight-releases/main/install.sh | bash
```

## Install by hand

**[Download Overnight for Windows](https://github.com/nnovoselski04/overnight-releases/releases/latest/download/Overnight-Setup.exe)** (64-bit, Windows 10 or 11)

1. Open `Overnight-Setup.exe`. It installs in about 30 seconds and doesn't need admin rights.
2. Windows may show **"Windows protected your PC"**. This is normal for a new app. Click **More info**, then **Run anyway**.
   **"Smart App Control blocked an app that may be unsafe"** (Windows 11) has no Run anyway: Smart App Control only lets
   signed apps start, and Overnight is not code-signed yet. To check the file is ours, run `Get-FileHash` on it in
   PowerShell (for example `Get-FileHash $env:USERPROFILE\Downloads\Overnight-Setup.exe`): the SHA-256 must match
   `SHA256SUMS.txt` on the [latest release](https://github.com/nnovoselski04/overnight-releases/releases/latest). To
   install Overnight, Smart App Control has to be off: Windows Security > App & browser control > Smart App Control >
   Off. That is your decision: on many Windows 11 versions it can only be turned on again by resetting Windows. The
   one-line installer above can't get around it either.
3. Log in with your **Skool** account. Overnight comes with the [Overnight community on Skool](https://www.skool.com/overnight-ai-video-automation-5588), and your tier there sets your plan.
4. Follow the setup checklist on the Home page. It connects your own **Claude** (Claude Code with your Claude plan) and checks or installs the tools the app needs: git, ffmpeg and Python.

## Updates

Overnight updates itself. It checks for a new version in the background, downloads only what changed, and installs it when you close the app (or press **Restart now** in Settings > Updates). Your projects and settings stay.

An update that says **"Failed to uninstall old application files"**, or one that closed Overnight and left it on the
old version (0.4.9 and older): run the one-line installer above. It moves the old version aside and installs the new
one into an empty folder; your projects, settings and Skool login stay.

## Plans

| | Standard | Max |
|---|---|---|
| Styles | 7 styles | Every style |
| Exports | 10 a month, 1080p | Unlimited, up to 4K |
| Deep Polish, other languages | No | Yes |

## Mac (by hand)

macOS 12 or newer. Apple menu > About This Mac: "Chip: Apple M…" takes the first, "Processor: Intel" the second.

- **[Download Overnight for Mac, Apple chip](https://github.com/nnovoselski04/overnight-releases/releases/latest/download/Overnight-Mac-AppleChip.dmg)**
- **[Download Overnight for Mac, Intel](https://github.com/nnovoselski04/overnight-releases/releases/latest/download/Overnight-Mac-Intel.dmg)**

1. Open the dmg and drag **Overnight** into **Applications**. Open it from Applications.
2. macOS says it can't check the app: click **Done**. Then System Settings > Privacy & Security, scroll down, click **Open Anyway** and enter your Mac's password. From then on it opens normally.
3. If macOS says the app "is damaged": open Terminal, paste `xattr -cr /Applications/Overnight.app`, and open it again.
4. Log in with **Skool**, then follow the setup checklist on the Home page.

An Intel Mac has no Minecraft Shorts (the one style that needs Blender); every other style is there. On a Mac,
Overnight tells you when a new version is out and opens the download; drag the new app into Applications.

## Help

Ask in the [Overnight community](https://www.skool.com/overnight-ai-video-automation-5588).
