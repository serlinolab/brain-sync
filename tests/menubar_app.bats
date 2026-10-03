#!/usr/bin/env bats
# The engine installs and updates the SerlinoLab Brain menu-bar app (lib/menubar_app.sh, MAX-1629)
# from app/ in this repo: it arrives with the engine's own git self-update, so no browser ever
# touches it and Gatekeeper never asks. `open`, `pgrep` and `pkill` are stubs; the bundle is a
# real ad-hoc-signed .app built per test.
load 'helpers'

APP_NAME="SerlinoLab Brain.app"

setup() {
  brain_test_setup
  local bin="$BRAIN_ROOT/bin"; mkdir -p "$bin"
  printf '%s\n' '#!/bin/bash' 'echo "$*" >> "$BRAIN_ROOT/open.log"' > "$bin/open"
  # pgrep: "running" when $BRAIN_ROOT/running exists (holding the path the app runs from)
  printf '%s\n' '#!/bin/bash' '[ -f "$BRAIN_ROOT/running" ] || exit 1' \
    'case "$*" in *-x*) exit 0 ;; *) grep -qF -- "${@: -1}" "$BRAIN_ROOT/running" ;; esac' > "$bin/pgrep"
  printf '%s\n' '#!/bin/bash' 'echo "$*" >> "$BRAIN_ROOT/pkill.log"; rm -f "$BRAIN_ROOT/running"' > "$bin/pkill"
  chmod +x "$bin"/*
  PATH="$bin:$PATH"; export PATH
  BRAIN_APP_SOURCE="$BRAIN_ROOT/appsrc"; export BRAIN_APP_SOURCE
  mkdir -p "$HOME/Applications"
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/brain_launcher.sh"
  source "$REPO_ROOT/lib/menubar_app.sh"
}
teardown() { brain_test_teardown; }

# A real, ad-hoc-signed bundle at $1 with version $2.
make_bundle() {
  mkdir -p "$1/Contents/MacOS"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict>' \
    '<key>CFBundleIdentifier</key><string>com.serlinolab.brain</string>' \
    '<key>CFBundleExecutable</key><string>SerlinoLabBrain</string>' \
    "<key>CFBundleShortVersionString</key><string>$2</string>" '</dict></plist>' > "$1/Contents/Info.plist"
  printf '#!/bin/sh\nexit 0\n' > "$1/Contents/MacOS/SerlinoLabBrain"; chmod +x "$1/Contents/MacOS/SerlinoLabBrain"
  codesign --force --sign - "$1" 2>/dev/null
}
# What publish-to-engine.sh puts in app/.
publish() {
  local work="$BRAIN_ROOT/work-$1"; mkdir -p "$BRAIN_APP_SOURCE"
  make_bundle "$work/$APP_NAME" "$1"
  ditto -c -k --keepParent "$work/$APP_NAME" "$BRAIN_APP_SOURCE/serlinolab-brain.zip"
  shasum -a 256 "$BRAIN_APP_SOURCE/serlinolab-brain.zip" | cut -d' ' -f1 > "$BRAIN_APP_SOURCE/SHA256"
  echo "$1" > "$BRAIN_APP_SOURCE/VERSION"
}
version_at() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"; }

@test "a Mac without the app gets it in ~/Applications, and it is started" {
  publish 0.2.0
  ensure_menubar_app
  [ "$(version_at "$HOME/Applications/$APP_NAME")" = "0.2.0" ]
  codesign --verify --strict "$HOME/Applications/$APP_NAME"
  grep -qF -- "-g $HOME/Applications/$APP_NAME" "$BRAIN_ROOT/open.log"
  grep -q "installed the SerlinoLab Brain app 0.2.0" "$LOG"
}

@test "the same version already installed is left alone and nothing is logged" {
  publish 0.2.0
  ensure_menubar_app
  local before; before=$(stat -f %i "$HOME/Applications/$APP_NAME")
  : > "$LOG"
  ensure_menubar_app
  [ "$(stat -f %i "$HOME/Applications/$APP_NAME")" = "$before" ]
  [ ! -s "$LOG" ]
}

@test "a newer version replaces the old one, and a running copy is restarted on the new one" {
  make_bundle "$HOME/Applications/$APP_NAME" 0.1.0
  echo "$HOME/Applications/$APP_NAME/Contents/MacOS/SerlinoLabBrain" > "$BRAIN_ROOT/running"
  publish 0.2.0
  ensure_menubar_app
  [ "$(version_at "$HOME/Applications/$APP_NAME")" = "0.2.0" ]
  grep -qF -- "$HOME/Applications/$APP_NAME/Contents/MacOS/SerlinoLabBrain" "$BRAIN_ROOT/pkill.log"
  grep -qF -- "-g $HOME/Applications/$APP_NAME" "$BRAIN_ROOT/open.log"
  [ -z "$(ls -A "$HOME/Applications" | grep -v "^$APP_NAME\$")" ]   # no temp or old copies left
}

@test "a copy dragged into /Applications from the DMG is updated there, never duplicated" {
  local sys="$BRAIN_ROOT/SysApplications"; mkdir -p "$sys"
  BRAIN_APP_DIRS="$sys:$HOME/Applications"
  make_bundle "$sys/$APP_NAME" 0.1.0
  publish 0.2.0
  ensure_menubar_app
  [ "$(version_at "$sys/$APP_NAME")" = "0.2.0" ]
  [ ! -e "$HOME/Applications/$APP_NAME" ]
}

@test "a zip whose checksum doesn't match is never installed" {
  make_bundle "$HOME/Applications/$APP_NAME" 0.1.0
  publish 0.2.0
  echo 0000 > "$BRAIN_APP_SOURCE/SHA256"
  ensure_menubar_app
  [ "$(version_at "$HOME/Applications/$APP_NAME")" = "0.1.0" ]
  grep -q "checksum" "$LOG"
}

@test "a bundle whose signature is broken is never installed, and the old one stays" {
  make_bundle "$HOME/Applications/$APP_NAME" 0.1.0
  local work="$BRAIN_ROOT/tampered"; make_bundle "$work/$APP_NAME" 0.2.0
  printf '#!/bin/sh\necho changed\n' > "$work/$APP_NAME/Contents/MacOS/SerlinoLabBrain"   # after signing
  mkdir -p "$BRAIN_APP_SOURCE"
  ditto -c -k --keepParent "$work/$APP_NAME" "$BRAIN_APP_SOURCE/serlinolab-brain.zip"
  shasum -a 256 "$BRAIN_APP_SOURCE/serlinolab-brain.zip" | cut -d' ' -f1 > "$BRAIN_APP_SOURCE/SHA256"
  echo 0.2.0 > "$BRAIN_APP_SOURCE/VERSION"
  ensure_menubar_app
  [ "$(version_at "$HOME/Applications/$APP_NAME")" = "0.1.0" ]
  grep -q "signature" "$LOG"
}

@test "a zip that says one version but contains another is not installed" {
  publish 0.2.0
  echo 0.3.0 > "$BRAIN_APP_SOURCE/VERSION"
  ensure_menubar_app
  [ ! -e "$HOME/Applications/$APP_NAME" ]
}

@test "an app the person quit from its menu is not started again" {
  publish 0.2.0
  ensure_menubar_app
  rm -f "$BRAIN_ROOT/open.log"
  : > "$STATE/app-quit"
  ensure_menubar_app
  [ ! -e "$BRAIN_ROOT/open.log" ]
}

@test "an app that is already running is not started a second time" {
  publish 0.2.0
  ensure_menubar_app
  rm -f "$BRAIN_ROOT/open.log"
  echo "/somewhere/else/SerlinoLabBrain" > "$BRAIN_ROOT/running"   # e.g. a developer build
  ensure_menubar_app
  [ ! -e "$BRAIN_ROOT/open.log" ]
}

@test "an engine without app/ does nothing at all" {
  ensure_menubar_app
  [ ! -e "$HOME/Applications/$APP_NAME" ]
  [ ! -e "$BRAIN_ROOT/open.log" ]
  [ ! -s "$LOG" ]
}

@test "a cycle runs it, and a failure in it never fails the cycle" {
  publish 0.2.0
  echo 0000 > "$BRAIN_APP_SOURCE/SHA256"
  run run_sync_cycle
  grep -q "checksum" "$LOG"
}

@test "test cycles never see this repo's real app/ build" {
  # helpers.bash points BRAIN_APP_SOURCE away; without that, every test cycle in every file would
  # install and launch the real app on the developer's Mac.
  run bash -c "source '$REPO_ROOT/tests/helpers.bash'; brain_test_setup; printf '%s' \"\$BRAIN_APP_SOURCE\"; brain_test_teardown"
  [[ "$output" == */no-app-source ]] || false
}

@test "every test file that runs a real cycle or setup isolates the real app" {
  # Review 2026-10-03: setup.bats runs sync.sh ~15 times without brain_test_setup, so it would
  # have installed and launched the real app. Structural guard: any file that invokes sync.sh,
  # setup.sh or the launcher must go through one of the two helpers that redirect the app.
  local f code bad=""
  for f in "$REPO_ROOT"/tests/*.bats; do
    # Code only, both ways: a comment naming setup.sh doesn't make a file run it, and a comment
    # naming the helper doesn't make a file call it.
    code=$(grep -vE '^[[:space:]]*#' "$f")
    grep -qE '(sync|setup|launcher)\.sh|run_sync_cycle|run_second_mac_sync_cycle' <<<"$code" || continue
    grep -qE 'brain_test_setup|isolate_real_app' <<<"$code" || bad="$bad $(basename "$f")"
  done
  [ -z "$bad" ] || { echo "not isolated:$bad"; false; }
}

# Review 2026-10-03: a failed install must never stop the "keep running" step.
@test "a failed update still keeps the installed copy running" {
  make_bundle "$HOME/Applications/$APP_NAME" 0.1.0
  publish 0.2.0
  echo 0000 > "$BRAIN_APP_SOURCE/SHA256"
  ensure_menubar_app
  grep -qF -- "-g $HOME/Applications/$APP_NAME" "$BRAIN_ROOT/open.log"
}

@test "the same problem is logged once, not every cycle" {
  publish 0.2.0
  echo 0000 > "$BRAIN_APP_SOURCE/SHA256"
  ensure_menubar_app; ensure_menubar_app; ensure_menubar_app
  [ "$(grep -c "checksum" "$LOG")" -eq 1 ]
}

@test "a folder the engine can't write is reported once and never duplicated into ~/Applications" {
  local sys="$BRAIN_ROOT/SysApplications"; mkdir -p "$sys"
  BRAIN_APP_DIRS="$sys:$HOME/Applications"
  make_bundle "$sys/$APP_NAME" 0.1.0
  chmod 555 "$sys"
  publish 0.2.0
  ensure_menubar_app; ensure_menubar_app
  chmod 755 "$sys"
  [ "$(version_at "$sys/$APP_NAME")" = "0.1.0" ]
  [ ! -e "$HOME/Applications/$APP_NAME" ]
  [ "$(grep -c "SerlinoLab Brain app 0.2.0" "$LOG")" -eq 1 ]
}

# Leftover names are lib/menubar_app.sh's own: ".$BRAIN_APP_NAME.{installing,old}.<pid>".
@test "leftovers of a cycle killed mid-install are cleaned up, and a moved-aside app is put back" {
  make_bundle "$HOME/Applications/.SerlinoLab Brain.installing.999/$APP_NAME" 0.1.0
  make_bundle "$HOME/Applications/.SerlinoLab Brain.old.998" 0.1.0   # killed between the two mv: no target
  publish 0.2.0
  ensure_menubar_app
  [ "$(version_at "$HOME/Applications/$APP_NAME")" = "0.2.0" ]
  [ -z "$(ls -A "$HOME/Applications" | grep -v "^$APP_NAME\$")" ]
}

@test "an app moved aside in /Applications by a killed cycle is restored there, not reinstalled elsewhere" {
  local sys="$BRAIN_ROOT/SysApplications"; mkdir -p "$sys"
  BRAIN_APP_DIRS="$sys:$HOME/Applications"
  make_bundle "$sys/.SerlinoLab Brain.old.998" 0.2.0
  publish 0.2.0
  ensure_menubar_app
  [ "$(version_at "$sys/$APP_NAME")" = "0.2.0" ]
  [ ! -e "$HOME/Applications/$APP_NAME" ]
}

# Re-review 2026-10-03: one remembered problem per kind (install / start), each cleared when that
# step succeeds - so two problems at once don't alternate into spam, and a recurrence is logged.
@test "an install problem and a start problem together are each logged once" {
  printf '%s\n' '#!/bin/bash' 'exit 1' > "$BRAIN_ROOT/bin/open"
  make_bundle "$HOME/Applications/$APP_NAME" 0.1.0
  publish 0.2.0
  echo 0000 > "$BRAIN_APP_SOURCE/SHA256"
  ensure_menubar_app; ensure_menubar_app; ensure_menubar_app
  [ "$(grep -c "checksum" "$LOG")" -eq 1 ]
  [ "$(grep -c "could not start" "$LOG")" -eq 1 ]
}

@test "a start failure that comes back after a success is logged again" {
  publish 0.2.0
  ensure_menubar_app                                                 # installed, started
  printf '%s\n' '#!/bin/bash' 'exit 1' > "$BRAIN_ROOT/bin/open"; ensure_menubar_app   # fails: logged
  printf '%s\n' '#!/bin/bash' 'exit 0' > "$BRAIN_ROOT/bin/open"; ensure_menubar_app   # recovers
  printf '%s\n' '#!/bin/bash' 'exit 1' > "$BRAIN_ROOT/bin/open"; ensure_menubar_app   # fails again: logged
  [ "$(grep -c "could not start" "$LOG")" -eq 2 ]
}

# Max, 2026-10-03: "after a reboot nobody relaunches it". The launchd job runs at login
# (RunAtLoad), so the app comes back by itself - except after a quit from its menu, whose marker
# used to survive reboots. A quit now lasts until the next boot.
@test "an app quit before the last reboot is started again" {
  publish 0.2.0
  ensure_menubar_app
  rm -f "$BRAIN_ROOT/open.log"
  : > "$STATE/app-quit"
  touch -t 202601010000 "$STATE/app-quit"                  # quit long before...
  BRAIN_BOOT_TIME=$(date -j -f %Y%m%d%H%M 202601020000 +%s)  # ...this boot
  ensure_menubar_app
  grep -qF -- "-g $HOME/Applications/$APP_NAME" "$BRAIN_ROOT/open.log"
  [ ! -e "$STATE/app-quit" ]
}

@test "an app quit since the last boot stays quit" {
  publish 0.2.0
  ensure_menubar_app
  rm -f "$BRAIN_ROOT/open.log"
  BRAIN_BOOT_TIME=$(( $(date +%s) - 3600 ))
  : > "$STATE/app-quit"
  ensure_menubar_app
  [ ! -e "$BRAIN_ROOT/open.log" ]
  [ -e "$STATE/app-quit" ]
}

@test "the boot time comes from the kernel when not overridden" {
  # Review: `.*sec = ` is greedy and matched "usec = 632934" - a number, and earlier than now, so
  # the old version of this test passed while the feature never fired. Pin it to kern.boottime's
  # own `sec` field, which must be a real recent epoch.
  unset BRAIN_BOOT_TIME
  local t sec; t=$(menubar_boot_time)
  sec=$(sysctl -n kern.boottime | tr -d '{},' | awk '{for (i=1;i<NF;i++) if ($i=="sec") {print $(i+2); exit}}')
  [ "$t" = "$sec" ]
  [ "$t" -gt 1577836800 ]          # after 2020-01-01
  [ "$t" -le "$(date +%s)" ]
}

# README review 2026-10-03: the launcher step used to run BEFORE the app step, so a brand-new
# Mac's first cycle still built the old launcher (and its Desktop shortcut) just before
# installing the app that replaces it.
@test "a brand-new Mac gets the app and never the old launcher" {
  publish 0.2.0
  CLAUDE_APP="$BRAIN_ROOT/Claude.app"; export CLAUDE_APP; mkdir -p "$CLAUDE_APP"
  make_fake_team_repo; make_fake_mirror        # a full cycle, Brain folder present
  [ -d "$HOME/Applications/$APP_NAME" ]
  [ ! -e "$HOME/Applications/Serlino Brain.app" ]
}

# The app needs macOS 14. Below it the engine must not install it - an installed copy that can't
# start would also switch the old launcher off, leaving that Mac with neither.
@test "below macOS 14 the app is not installed, so the old launcher stays" {
  publish 0.2.0
  BRAIN_MACOS_VERSION=13.6.9 ensure_menubar_app
  [ ! -e "$HOME/Applications/$APP_NAME" ]
  BRAIN_MACOS_VERSION=14.0 ensure_menubar_app
  [ -d "$HOME/Applications/$APP_NAME" ]
}
