# Overnight

Overnight turns a voiceover into a finished video. Claude writes the scenes, and the app draws and exports them.

## Set up with Claude

Have the Claude desktop app? Open **Claude Code** in it and paste this line, on Windows or on a Mac. Claude installs
Overnight and what it needs (git, ffmpeg, Python, Claude Code), checks that it really opens, and tells you what to do next:

```
Set up Overnight for me: https://github.com/nnovoselski04/overnight-releases
```

Overnight installed but broken (won't open, stays dark, a step keeps failing)? Paste this instead:

```
Fix Overnight for me: https://github.com/nnovoselski04/overnight-releases
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
3. Log in with your **Skool** account. Overnight comes with the [Overnight community on Skool](https://www.skool.com/overnight-ai-video-automation-5588), and your tier there sets your plan.
4. Follow the setup checklist on the Home page. It connects your own **Claude** (Claude Code with your Claude plan) and checks or installs the tools the app needs: git, ffmpeg and Python.

## Updates

Overnight updates itself. It checks for a new version in the background, downloads only what changed, and installs it when you close the app (or press **Restart now** in Settings > Updates). Your projects and settings stay.

## Plans

| | Standard | Max |
|---|---|---|
| Styles | 7 styles: Flat Explainer, MS Paint Stick Figures, Paper Cut, Pixel Art, Newspaper Collage, Low Poly Shorts, Chibi Sticker Lore | Every style, including Roblox Story Shorts, 3D Cartoon Shorts, Stickman Cinema, History War Maps and Realistic 3D Explainer |
| Exports | 10 a month, 1080p | Unlimited, up to 4K |
| Ultraedit, Style Studio, other languages | No | Yes |

## Mac (by hand)

macOS 12 or newer. Apple menu > About This Mac: "Chip: Apple M…" takes the first, "Processor: Intel" the second.

- **[Download Overnight for Mac, Apple chip](https://github.com/nnovoselski04/overnight-releases/releases/latest/download/Overnight-Mac-AppleChip.dmg)**
- **[Download Overnight for Mac, Intel](https://github.com/nnovoselski04/overnight-releases/releases/latest/download/Overnight-Mac-Intel.dmg)**

1. Open the dmg and drag **Overnight** into **Applications**. Open it from Applications.
2. macOS says it can't check the app: click **Done**. Then System Settings > Privacy & Security, scroll down, click **Open Anyway** and enter your Mac's password. From then on it opens normally.
3. If macOS says the app "is damaged": open Terminal, paste `xattr -cr /Applications/Overnight.app`, and open it again.
4. Log in with **Skool**, then follow the setup checklist on the Home page.

An Intel Mac has no Blender styles (Minecraft Shorts, the 3D cartoon styles); every other style is there. On a Mac,
Overnight tells you when a new version is out and opens the download; drag the new app into Applications.

## Help

Ask in the [Overnight community](https://www.skool.com/overnight-ai-video-automation-5588).
