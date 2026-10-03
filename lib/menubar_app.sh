#!/bin/bash
# The SerlinoLab Brain menu-bar app (serlinolab/brain-app, MAX-1629): installed, updated and kept
# running by the engine. The app's build lives in this repo under app/ (put there by brain-app's
# scripts/publish-to-engine.sh), so it reaches every Mac with the engine's own git self-update -
# no browser download, hence no quarantine and no Gatekeeper prompt, and no trust root beyond the
# one this engine already has: protected `main` of this repo.
#
# Sourced by sync.sh after lib/brain_launcher.sh (which defines BRAIN_APP_NAME, BRAIN_APP_DIRS and
# brain_menubar_app_installed). Never fails its caller: every problem is logged and skipped.
BRAIN_APP_SOURCE="${BRAIN_APP_SOURCE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/app}"
BRAIN_APP_EXECUTABLE="SerlinoLabBrain"

# The installed copy: the first folder in BRAIN_APP_DIRS that holds a real bundle (a person may
# have dragged it into /Applications from the DMG). None: ~/Applications, where this engine can
# always write. Never two copies.
menubar_app_target(){
  local d IFS=:
  for d in $BRAIN_APP_DIRS; do
    [ -f "$d/$BRAIN_APP_NAME.app/Contents/Info.plist" ] && { printf '%s' "$d/$BRAIN_APP_NAME.app"; return; }
  done
  printf '%s' "$HOME/Applications/$BRAIN_APP_NAME.app"
}

menubar_app_version(){
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null
}

# A problem is logged once, not every 5 minutes. One remembered problem per KIND (install, start):
# both can fail at once (a Mac on an older macOS that also can't write /Applications), and a single
# shared slot would alternate between them and log both every cycle. Each kind is cleared when its
# step succeeds, so the same problem coming back later is logged again.
menubar_app_log(){
  local kind="$1"; shift
  local last="$STATE/menubar-app-problem-$kind"
  [ "$(cat "$last" 2>/dev/null)" = "$*" ] && return 0
  printf '%s\n' "$*" > "$last" 2>/dev/null
  log "$*"
}
menubar_app_ok(){ rm -f "$STATE/menubar-app-problem-$1"; }

ensure_menubar_app(){
  local zip="$BRAIN_APP_SOURCE/serlinolab-brain.zip"
  [ -f "$zip" ] || return 0
  local want target
  menubar_app_recover
  want=$(tr -d '[:space:]' < "$BRAIN_APP_SOURCE/VERSION" 2>/dev/null)
  target=$(menubar_app_target)
  if [ -n "$want" ] && [ "$(menubar_app_version "$target")" != "$want" ]; then
    # A failed install never stops the step below: the copy already installed keeps running.
    install_menubar_app "$zip" "$want" "$target" || true
  fi
  start_menubar_app "$target"
  return 0
}

# A cycle killed mid-install (logout, power) can leave `.installing.N` / `.old.N` beside the
# target, and if it died between the two renames, NO target at all. Put a moved-aside app back
# first (so the target folder is found where it was, never duplicated into ~/Applications), then
# remove the rest. Safe: every caller holds the sync lock, so no other install is in flight.
menubar_app_recover(){
  local d old IFS=:
  for d in $BRAIN_APP_DIRS $HOME/Applications; do
    [ -d "$d" ] || continue
    if [ ! -e "$d/$BRAIN_APP_NAME.app" ]; then
      for old in "$d/.$BRAIN_APP_NAME.old."*; do
        [ -f "$old/Contents/Info.plist" ] && mv "$old" "$d/$BRAIN_APP_NAME.app" 2>/dev/null && break
      done
    fi
    rm -rf "$d/.$BRAIN_APP_NAME.installing."* "$d/.$BRAIN_APP_NAME.old."* 2>/dev/null
  done
}

install_menubar_app(){
  local zip="$1" want="$2" target="$3" sum dir tmp old new
  sum=$(shasum -a 256 "$zip" 2>/dev/null | cut -d' ' -f1)
  if [ -z "$sum" ] || [ "$sum" != "$(tr -d '[:space:]' < "$BRAIN_APP_SOURCE/SHA256" 2>/dev/null)" ]; then
    menubar_app_log install "SerlinoLab Brain app $want: checksum does not match app/SHA256; not installing"
    return 1
  fi
  dir=$(dirname "$target")
  mkdir -p "$dir" 2>/dev/null
  # Unpacked beside the target (same volume, so the swap below is a rename) and checked before
  # anything existing is touched.
  tmp="$dir/.$BRAIN_APP_NAME.installing.$$"
  rm -rf "$tmp"
  new="$tmp/$BRAIN_APP_NAME.app"
  if ! mkdir -p "$tmp" 2>/dev/null || ! ditto -x -k "$zip" "$tmp" 2>/dev/null || [ ! -d "$new" ]; then
    rm -rf "$tmp"; menubar_app_log install "SerlinoLab Brain app $want: could not unpack into $dir; not installing"; return 1
  fi
  if ! codesign --verify --strict "$new" 2>/dev/null; then
    rm -rf "$tmp"; menubar_app_log install "SerlinoLab Brain app $want: signature does not verify; not installing"; return 1
  fi
  if [ "$(menubar_app_version "$new")" != "$want" ]; then
    rm -rf "$tmp"; menubar_app_log install "SerlinoLab Brain app: the zip does not contain version $want; not installing"; return 1
  fi
  # A copy running from the target is stopped only now, with its replacement verified.
  local was_running=0
  if pgrep -f "$target/Contents/MacOS/$BRAIN_APP_EXECUTABLE" >/dev/null 2>&1; then
    was_running=1
    pkill -f "$target/Contents/MacOS/$BRAIN_APP_EXECUTABLE" 2>/dev/null
  fi
  old=""
  if [ -e "$target" ]; then
    old="$dir/.$BRAIN_APP_NAME.old.$$"
    mv "$target" "$old" 2>/dev/null || { rm -rf "$tmp"; menubar_app_log install "SerlinoLab Brain app $want: could not move the old copy aside in $dir; not installing"; return 1; }
  fi
  if ! mv "$new" "$target" 2>/dev/null; then
    [ -n "$old" ] && mv "$old" "$target"
    rm -rf "$tmp"; menubar_app_log install "SerlinoLab Brain app $want: could not put the new copy in place; kept the old one"; return 1
  fi
  rm -rf "$tmp" ${old:+"$old"}
  log "installed the SerlinoLab Brain app $want at $target"
  menubar_app_ok install
  [ "$was_running" -eq 1 ] && rm -f "$STATE/app-quit"   # it was running: bring it back on the new version
  return 0
}

# When this Mac last booted, in epoch seconds (kern.boottime). BRAIN_BOOT_TIME overrides it for tests.
menubar_boot_time(){
  [ -n "${BRAIN_BOOT_TIME:-}" ] && { printf '%s' "$BRAIN_BOOT_TIME"; return; }
  # `{ sec = 1790852603, usec = 632934 } Thu Oct ...`: anchor on "{ sec", never "usec".
  sysctl -n kern.boottime 2>/dev/null | sed -nE 's/^\{ sec = ([0-9]+),.*/\1/p'
}

# Kept running, unless the person quit it from its menu ($STATE/app-quit, written by the app and
# removed when it starts) or a copy is already running (any copy - a developer build counts).
# A quit lasts until the next boot (Max, 2026-10-03): the job runs at login (RunAtLoad), so after a
# restart the app comes back by itself even if it was quit before - a marker older than the boot
# is dropped. An unreadable boot time keeps the marker (never overrides a quit by guessing).
start_menubar_app(){
  [ -f "$1/Contents/Info.plist" ] || return 0
  if [ -e "$STATE/app-quit" ]; then
    local boot quit
    boot=$(menubar_boot_time); quit=$(stat -f %m "$STATE/app-quit" 2>/dev/null)
    if [ -n "$boot" ] && [ -n "$quit" ] && [ "$quit" -lt "$boot" ]; then
      rm -f "$STATE/app-quit"
    else
      return 0
    fi
  fi
  pgrep -x "$BRAIN_APP_EXECUTABLE" >/dev/null 2>&1 && return 0
  if open -g "$1" >/dev/null 2>&1; then menubar_app_ok start
  else menubar_app_log start "could not start the SerlinoLab Brain app"; fi
}
