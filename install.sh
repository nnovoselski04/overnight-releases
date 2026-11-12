#!/bin/bash
# Overnight installer for macOS: what Overnight needs before its first start, then Overnight itself.
#   curl -fsSL https://raw.githubusercontent.com/nnovoselski04/overnight-releases/main/install.sh | bash
# Safe to run again: it skips what is already there, updates Overnight when a newer version is out, and puts back what
# is missing. Plain bash 3.2 (the one every Mac has), no sudo, nothing outside the places below.
#
# What it does (each only when missing):
#   git        Apple's Command Line Tools. Missing: it opens Apple's own Install window (the member clicks Install).
#   Claude Code   only if `claude` is not found: https://claude.ai/install.sh
#   Overnight  the newest release with a Mac build for this chip, into /Applications/Overnight.app
#              (~/Applications when /Applications can't be written)
# ffmpeg and Python are NOT installed here: on a Mac the app installs its own (Home > Install your tools > Set up),
# with its Python packages, after the Skool login. This script never writes into Overnight's data.
#
# Switches (environment variables):
#   OVERNIGHT_SETUP_DRY=1    test mode: look and report, change nothing
#   OVERNIGHT_NO_OPEN=1      don't start Overnight at the end
#   OVERNIGHT_CLOSE_APP=1    the member said yes: an open Overnight may be closed to update it (only Overnight itself)
#   OVERNIGHT_REINSTALL=1    repair: install the newest Overnight again even when it is up to date (projects, settings
#                            and the Skool login stay)
# How it ends: 0 = all set; 3 = finished, with problems left (listed at the end); 1 = stopped (the reason is printed).
# Its output also goes to $TMPDIR/overnight-setup/install.log.

main() {
set -u
OWNER='nnovoselski04'
REPO='overnight-releases'
ONE_LINE="curl -fsSL https://raw.githubusercontent.com/$OWNER/$REPO/main/install.sh | bash"
DL="${TMPDIR:-/tmp}"; DL="${DL%/}/overnight-setup"
LOG="$DL/install.log"
DRY="${OVERNIGHT_SETUP_DRY:-}"
NO_OPEN="${OVERNIGHT_NO_OPEN:-}"
CLOSE_APP="${OVERNIGHT_CLOSE_APP:-}"
REINSTALL="${OVERNIGHT_REINSTALL:-}"
PROBLEMS=()
NEXT=()
MOUNT=''

mkdir -p "$DL" || { echo "Install stopped: could not make the folder $DL"; return 1; }
put() { printf '%s\n' "$1"; printf '%s\n' "$1" >> "$LOG" 2>/dev/null; }
step() { put ''; put "==> $1"; }
ok() { put "    [ok] $1"; }
note() { put "    $1"; }
warn() { put "    [!] $1"; }
problem() { PROBLEMS+=("$1"); warn "$1"; }
unmount() { if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet 2>/dev/null || hdiutil detach "$MOUNT" -force -quiet 2>/dev/null; fi; MOUNT=''; }
stop() { unmount; put ''; put "Install stopped: $1"; put ''; put "Fix that, then run it again: $ONE_LINE"; return 1; }

put "Overnight setup for Mac, $(date '+%Y-%m-%d %H:%M')$([ -n "$DRY" ] && echo ' (test mode: nothing is changed)')"

# ---- this computer ----
step 'This computer'
if [ "$(uname -s)" != 'Darwin' ]; then stop 'this script is for a Mac. On Windows use install.ps1 (see the README).'; return 1; fi
OSV="$(sw_vers -productVersion 2>/dev/null)"; OSMAJOR="${OSV%%.*}"
ARM="$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)"
if [ "$ARM" = '1' ]; then CHIP='Apple chip'; DMG='Overnight-Mac-AppleChip.dmg'; else CHIP='Intel'; DMG='Overnight-Mac-Intel.dmg'; fi
ok "macOS $OSV, $CHIP ($(uname -m) shell)"
case "$OSMAJOR" in ''|*[!0-9]*) OSMAJOR=0 ;; esac
if [ "$OSMAJOR" -lt 12 ]; then stop "Overnight needs macOS 12 (Monterey) or newer; this Mac has $OSV. Update macOS in System Settings > General > Software Update."; return 1; fi
FREE_KB="$(df -k "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"; case "$FREE_KB" in ''|*[!0-9]*) FREE_KB=0 ;; esac
FREE_GB=$((FREE_KB / 1048576))
if [ "$FREE_GB" -lt 8 ]; then problem "only $FREE_GB GB free on this Mac. Overnight and its tools need about 8 GB: free some space."; else ok "$FREE_GB GB free"; fi
[ "$CHIP" = 'Intel' ] && note 'On an Intel Mac the Blender styles are not available (Blender 5 has no Intel Mac build).'
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then warn 'ANTHROPIC_API_KEY is set: Claude Code may bill that key instead of your Claude plan.'; fi

# ---- git (Apple's Command Line Tools) ----
step 'git (Apple Command Line Tools)'
if xcode-select -p >/dev/null 2>&1 && /usr/bin/git --version >/dev/null 2>&1; then
  ok "$(/usr/bin/git --version 2>/dev/null) ($(xcode-select -p 2>/dev/null))"
elif command -v git >/dev/null 2>&1 && [ "$(command -v git)" != '/usr/bin/git' ] && git --version >/dev/null 2>&1; then
  ok "$(git --version) ($(command -v git))"
elif [ -n "$DRY" ]; then
  note "(test mode) would open Apple's Install window for the Command Line Tools (git)"
else
  xcode-select --install >/dev/null 2>&1
  warn "git is not on this Mac yet. Apple's window \"Install Command Line Developer Tools\" is open: click Install (about 5 to 15 minutes)."
  NEXT+=("Finish Apple's Command Line Tools install (the window that opened). Overnight uses its git to save every change.")
fi

# ---- Claude Code ----
step 'Claude Code'
CL="$(command -v claude 2>/dev/null)"; [ -z "$CL" ] && [ -x "$HOME/.local/bin/claude" ] && CL="$HOME/.local/bin/claude"
if [ -n "$CL" ]; then
  ok "Claude Code $("$CL" --version 2>/dev/null | head -1) ($CL)"
elif [ -n "$DRY" ]; then
  note '(test mode) would install Claude Code from https://claude.ai/install.sh'
else
  note 'Installing Claude Code (https://claude.ai/install.sh) ...'
  if curl -fsSL -o "$DL/claude-install.sh" https://claude.ai/install.sh && bash "$DL/claude-install.sh" >> "$LOG" 2>&1 && [ -x "$HOME/.local/bin/claude" ]; then
    ok "Claude Code $("$HOME/.local/bin/claude" --version 2>/dev/null | head -1) ($HOME/.local/bin/claude)"
  else
    warn 'Claude Code did not install: claude.ai could not be reached, or its installer failed. Overnight works meanwhile with its built-in Claude Code.'
  fi
  rm -f "$DL/claude-install.sh"
fi

# ---- Overnight ----
step 'Overnight'
APP=''
for d in '/Applications/Overnight.app' "$HOME/Applications/Overnight.app"; do [ -d "$d" ] && { APP="$d"; break; }; done
HAVE=''
[ -n "$APP" ] && HAVE="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
[ -n "$APP" ] && note "installed: Overnight ${HAVE:-(version not readable)} in $APP"
running() { [ -n "$APP" ] && pgrep -f "^$APP/Contents/MacOS/Overnight" >/dev/null 2>&1; }

# the newest release with this chip's dmg. First the plain download link (no GitHub API: its hourly limit per network
# stops shared connections); when the newest release has no Mac build yet, the API finds the newest one that has
PICK=''
LOC="$(curl -fsSI --retry 2 "https://github.com/$OWNER/$REPO/releases/latest/download/$DMG" 2>/dev/null | tr -d '' | awk 'tolower($1) == "location:" {print $2}' | tail -1)"
case "$LOC" in "https://github.com/$OWNER/$REPO/releases/download/v"*"/$DMG")
  TAG="${LOC#https://github.com/$OWNER/$REPO/releases/download/}"; TAG="${TAG%%/*}"
  LEN="$(curl -fsSIL --retry 2 "$LOC" 2>/dev/null | tr -d '' | awk 'tolower($1) == "content-length:" {n = $2} END {print n}')"
  case "$LEN" in ''|*[!0-9]*) ;; *) [ "$LEN" -gt 100000000 ] && PICK="$(printf '%s
%s
%s' "${TAG#v}" "$LEN" "$LOC")" ;; esac ;;
esac
if [ -z "$PICK" ]; then
API="https://api.github.com/repos/$OWNER/$REPO/releases?per_page=10"
if ! curl -fsSL --retry 2 -o "$DL/releases.json" "$API"; then stop "could not reach https://github.com/$OWNER/$REPO/releases (no internet, or a firewall, proxy or VPN blocks github.com)."; return 1; fi
PICK="$(/usr/bin/python3 - "$DL/releases.json" "$DMG" <<'PY' 2>/dev/null
import json, sys
for r in json.load(open(sys.argv[1])):
    if r.get('draft') or r.get('prerelease'): continue
    for a in r.get('assets', []):
        if a.get('name') == sys.argv[2]:
            print(r['tag_name'].lstrip('v')); print(a['size']); print(a['browser_download_url']); sys.exit(0)
PY
)"
if [ -z "$PICK" ]; then   # no python3 before the Command Line Tools: read the JSON with plutil (always there)
  N=0
  while [ "$N" -lt 10 ] && [ -z "$PICK" ]; do
    TAG="$(plutil -extract "$N.tag_name" raw -o - "$DL/releases.json" 2>/dev/null)" || break
    M=0
    while [ "$M" -lt 30 ]; do
      NAME="$(plutil -extract "$N.assets.$M.name" raw -o - "$DL/releases.json" 2>/dev/null)" || break
      if [ "$NAME" = "$DMG" ]; then
        PICK="$(printf '%s\n%s\n%s' "${TAG#v}" "$(plutil -extract "$N.assets.$M.size" raw -o - "$DL/releases.json")" "$(plutil -extract "$N.assets.$M.browser_download_url" raw -o - "$DL/releases.json")")"
        break
      fi
      M=$((M + 1))
    done
    N=$((N + 1))
  done
fi
rm -f "$DL/releases.json"
fi
NEW="$(printf '%s\n' "$PICK" | sed -n 1p)"; SIZE="$(printf '%s\n' "$PICK" | sed -n 2p)"; URL="$(printf '%s\n' "$PICK" | sed -n 3p)"
case "$URL" in "https://github.com/$OWNER/$REPO/releases/download/"*) ;; *) stop "no Mac build of Overnight was found in the releases (looked for $DMG)."; return 1 ;; esac
note "newest Mac build: Overnight $NEW ($DMG, $((SIZE / 1048576)) MB)"

NEED=1
if [ -n "$APP" ] && [ "$HAVE" = "$NEW" ] && [ -z "$REINSTALL" ]; then NEED=0; ok "Overnight $HAVE is up to date"; fi
if [ "$NEED" = 1 ] && running; then
  if [ "$CLOSE_APP" = '1' ] && [ -z "$DRY" ]; then
    note 'Closing Overnight ...'
    osascript -e 'tell application id "com.madeovernight.studio" to quit' >/dev/null 2>&1
    i=0; while running && [ "$i" -lt 20 ]; do sleep 1; i=$((i + 1)); done
    running && pkill -f "^$APP/Contents/MacOS/Overnight" 2>/dev/null; sleep 1
  fi
  if running; then NEED=0; problem "Overnight ${HAVE:-} is open, so it was not updated to $NEW. Close it (Overnight > Quit) and run this again."; fi
fi
if [ "$NEED" = 1 ] && [ -n "$DRY" ]; then
  NEED=0; note "(test mode) would download $DMG and put Overnight $NEW into ${APP:-/Applications/Overnight.app}"
fi
if [ "$NEED" = 1 ]; then
  note "Downloading Overnight $NEW (about $((SIZE / 1048576)) MB) ..."
  if ! curl -fL --retry 3 --retry-delay 3 -sS -o "$DL/$DMG" "$URL"; then rm -f "$DL/$DMG"; stop "the download of Overnight $NEW did not finish (the connection was cut, or something blocks github.com)."; return 1; fi
  GOT="$(stat -f %z "$DL/$DMG" 2>/dev/null || echo 0)"
  if [ "$GOT" != "$SIZE" ]; then rm -f "$DL/$DMG"; stop "the download of Overnight $NEW was damaged on the way ($GOT of $SIZE bytes). It was not opened."; return 1; fi
  MOUNT="$DL/mount"; rm -rf "$MOUNT"; mkdir -p "$MOUNT"
  if ! hdiutil attach "$DL/$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" >> "$LOG" 2>&1; then MOUNT=''; rm -f "$DL/$DMG"; stop "macOS could not open $DMG (the download is damaged). Run this again."; return 1; fi
  if [ ! -d "$MOUNT/Overnight.app" ]; then stop "$DMG does not hold Overnight.app."; return 1; fi
  if [ -z "$APP" ]; then
    if [ -w /Applications ]; then APP='/Applications/Overnight.app'; else mkdir -p "$HOME/Applications"; APP="$HOME/Applications/Overnight.app"; fi
  fi
  NEWAPP="$APP.new"; rm -rf "$NEWAPP"
  if ! ditto "$MOUNT/Overnight.app" "$NEWAPP" >> "$LOG" 2>&1; then rm -rf "$NEWAPP"; stop "could not copy Overnight into $(dirname "$APP") (no permission, or the disk is full)."; return 1; fi
  unmount
  rm -f "$DL/$DMG"
  # downloaded with curl, so macOS has no "from the internet" mark on it; cleared anyway (only Overnight's own app)
  xattr -cr "$NEWAPP" 2>/dev/null
  if ! codesign --verify --deep --strict "$NEWAPP" >> "$LOG" 2>&1; then rm -rf "$NEWAPP"; stop "the copied Overnight did not pass macOS's own check (codesign). It was not installed; run this again."; return 1; fi
  rm -rf "$APP.old"; [ -d "$APP" ] && mv "$APP" "$APP.old"
  if ! mv "$NEWAPP" "$APP"; then [ -d "$APP.old" ] && mv "$APP.old" "$APP"; stop "could not put Overnight into $(dirname "$APP")."; return 1; fi
  rm -rf "$APP.old"
  HAVE="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
  if [ "$HAVE" = "$NEW" ]; then ok "Overnight $HAVE installed in $APP"; else problem "Overnight was copied to $APP but its version reads '${HAVE:-nothing}' (expected $NEW)."; fi
fi

# ---- done ----
step 'Done'
if [ -z "$DRY" ] && [ -z "$NO_OPEN" ] && [ -n "$APP" ] && [ -d "$APP" ]; then
  if running; then note 'Overnight is already open.'; else open "$APP" && ok 'Overnight is starting'; fi
fi
NEXT+=("Log in with Skool in Overnight's window (the account you joined the community with).")
NEXT+=("On Home: Connect Claude (Sign in), then Install your tools > Set up (ffmpeg, Python and Overnight's packages, 10 to 30 minutes).")
put ''; put 'Next:'
for n in "${NEXT[@]}"; do put "  - $n"; done
put ''
if [ "${#PROBLEMS[@]}" -eq 0 ]; then
  put "$([ -n "$DRY" ] && echo 'Test mode finished: nothing was changed.' || echo 'All set.')"
  return 0
fi
put "Finished, with ${#PROBLEMS[@]} problem(s) left:"
for p in "${PROBLEMS[@]}"; do put "  - $p"; done
return 3
}
main "$@"
exit $?
