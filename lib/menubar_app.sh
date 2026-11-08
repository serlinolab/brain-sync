#!/bin/bash
# The Brain app on each Mac: installed, updated and kept running by the engine. Until 2026-11 the
# SerlinoLab Brain menu-bar app (serlinolab/brain-app, MAX-1629). The app's build lives in this repo under app/ (put there by brain-app's
# scripts/publish-to-engine.sh), so it reaches every Mac with the engine's own git self-update -
# no browser download, hence no quarantine and no Gatekeeper prompt, and no trust root beyond the
# one this engine already has: an allowed SSH signature on its commit. The ZIP checksum
# authenticates nothing by itself; its authority comes from that signed commit.
#
# Sourced by sync.sh after lib/brain_launcher.sh (which defines BRAIN_APP_NAME, BRAIN_APP_DIRS and
# brain_menubar_app_installed). Never fails its caller: every problem is logged and skipped.
#
# Since 2026-11 (serlinolab/brain-desktop 0.6.0) the one app "Serlino Brain" - the Brain window
# plus the same menu-bar dot, Fix and onboarding - replaces it. Its build is app/desktop/. When
# that build is present this file installs Serlino Brain instead, starts it with no window
# (`--background`), and once it is in place removes the old SerlinoLab Brain app this engine had
# installed. Without app/desktop/ nothing changes: the old app is installed exactly as before.
BRAIN_APP_SOURCE="${BRAIN_APP_SOURCE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/app}"
BRAIN_APP_EXECUTABLE="SerlinoLabBrain"
BRAIN_APP_DIR="$BRAIN_APP_SOURCE"            # where the zip, SHA256 and VERSION are read
BRAIN_APP_ZIP="serlinolab-brain.zip"
BRAIN_APP_OPEN_ARGS=()                       # extra arguments for `open`, before the bundle path
BRAIN_APP_LAUNCH_ARGS=()                     # arguments for the app itself (`open --args`)
BRAIN_APP_REPLACES=""                        # the older app this one retires, if any

# Picks the app this engine ships: Serlino Brain when its build is in app/desktop/.
menubar_app_select(){
  if [ -f "$BRAIN_APP_SOURCE/desktop/serlino-brain.zip" ]; then
    BRAIN_APP_NAME="Serlino Brain"
    BRAIN_APP_EXECUTABLE="SerlinoBrainDesktop"
    BRAIN_APP_DIR="$BRAIN_APP_SOURCE/desktop"
    BRAIN_APP_ZIP="serlino-brain.zip"
    BRAIN_APP_OPEN_ARGS=(-j)                  # launched hidden: no window at login
    BRAIN_APP_LAUNCH_ARGS=(--background)
    BRAIN_APP_REPLACES="SerlinoLab Brain"
  fi
}

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

# The app needs macOS 14 (LSMinimumSystemVersion). Below it nothing is installed: a copy that can't
# start would still count as installed and switch the old launcher off, leaving neither.
BRAIN_APP_MIN_MACOS_MAJOR=14
menubar_app_supported(){
  local v major
  v="${BRAIN_MACOS_VERSION:-$(sw_vers -productVersion 2>/dev/null)}"
  major="${v%%.*}"
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  [ "$major" -ge "$BRAIN_APP_MIN_MACOS_MAJOR" ]
}

ensure_menubar_app(){
  menubar_app_select
  local zip="$BRAIN_APP_DIR/$BRAIN_APP_ZIP"
  [ -f "$zip" ] || return 0
  menubar_app_supported || return 0
  local want target
  menubar_app_recover
  want=$(tr -d '[:space:]' < "$BRAIN_APP_DIR/VERSION" 2>/dev/null)
  target=$(menubar_app_target)
  if [ -n "$want" ] && [ "$(menubar_app_version "$target")" != "$want" ]; then
    # A failed install never stops the step below: the copy already installed keeps running.
    install_menubar_app "$zip" "$want" "$target" || true
  fi
  # The older app goes only once its replacement is in place at the shipped version.
  if [ -n "$BRAIN_APP_REPLACES" ] && [ -n "$want" ] && [ "$(menubar_app_version "$target")" = "$want" ]; then
    retire_replaced_app
  fi
  start_menubar_app "$target"
  return 0
}

# Removes the SerlinoLab Brain menu-bar app once Serlino Brain does its job: stops it, then deletes
# every copy (it was installed by this engine, or dragged from the DMG this engine replaces). A
# quit of the old app does not carry over: the person never quit Serlino Brain.
retire_replaced_app(){
  local d old found=0 failed="" IFS=:
  for d in $BRAIN_APP_DIRS $HOME/Applications; do
    [ -d "$d/$BRAIN_APP_REPLACES.app" ] && found=1
  done
  [ "$found" -eq 1 ] || return 0
  pkill -x "SerlinoLabBrain" 2>/dev/null
  for d in $BRAIN_APP_DIRS $HOME/Applications; do
    old="$d/$BRAIN_APP_REPLACES.app"
    [ -d "$old" ] || continue
    if rm -rf "$old" 2>/dev/null && [ ! -e "$old" ]; then
      log "removed the $BRAIN_APP_REPLACES app from $d: $BRAIN_APP_NAME replaces it"
    else
      failed="$d"
    fi
  done
  if [ -n "$failed" ]; then
    menubar_app_log retire "could not remove the $BRAIN_APP_REPLACES app from $failed; it stays, stopped at each cycle"
  else
    menubar_app_ok retire
    rm -f "$STATE/app-quit"
  fi
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
  if [ -z "$sum" ] || [ "$sum" != "$(tr -d '[:space:]' < "$BRAIN_APP_DIR/SHA256" 2>/dev/null)" ]; then
    menubar_app_log install "$BRAIN_APP_NAME app $want: checksum does not match its SHA256 file in app/; not installing"
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
    rm -rf "$tmp"; menubar_app_log install "$BRAIN_APP_NAME app $want: could not unpack into $dir; not installing"; return 1
  fi
  if ! codesign --verify --strict "$new" 2>/dev/null; then
    rm -rf "$tmp"; menubar_app_log install "$BRAIN_APP_NAME app $want: signature does not verify; not installing"; return 1
  fi
  if [ "$(menubar_app_version "$new")" != "$want" ]; then
    rm -rf "$tmp"; menubar_app_log install "$BRAIN_APP_NAME app: the zip does not contain version $want; not installing"; return 1
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
    mv "$target" "$old" 2>/dev/null || { rm -rf "$tmp"; menubar_app_log install "$BRAIN_APP_NAME app $want: could not move the old copy aside in $dir; not installing"; return 1; }
  fi
  if ! mv "$new" "$target" 2>/dev/null; then
    [ -n "$old" ] && mv "$old" "$target"
    rm -rf "$tmp"; menubar_app_log install "$BRAIN_APP_NAME app $want: could not put the new copy in place; kept the old one"; return 1
  fi
  rm -rf "$tmp" ${old:+"$old"}
  log "installed the $BRAIN_APP_NAME app $want at $target"
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
  local launch=()
  [ "${#BRAIN_APP_LAUNCH_ARGS[@]}" -gt 0 ] && launch=(--args "${BRAIN_APP_LAUNCH_ARGS[@]}")
  if open -g ${BRAIN_APP_OPEN_ARGS[@]+"${BRAIN_APP_OPEN_ARGS[@]}"} "$1" ${launch[@]+"${launch[@]}"} >/dev/null 2>&1; then menubar_app_ok start
  else menubar_app_log start "could not start the $BRAIN_APP_NAME app"; fi
}
