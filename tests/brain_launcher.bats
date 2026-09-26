#!/usr/bin/env bats
# The "Serlino Brain" launcher (lib/brain_launcher.sh). osacompile is stubbed; osadecompile and
# `open` are stubbed only to prove a cycle never decompiles and nothing here fires a claude://
# link. xattr is the real one - the stamp is an extended attribute on the app bundle.
load 'helpers'

setup() {
  brain_test_setup
  local bin="$BRAIN_ROOT/bin"; mkdir -p "$bin"
  cat > "$bin/osacompile" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; -e) src="$2"; shift ;; esac; shift; done
echo called >> "$BRAIN_ROOT/osacompile.log"
mkdir -p "$out/Contents/Resources/Scripts" && printf '%s' "$src" > "$out/Contents/Resources/Scripts/main.scpt"
EOF
  printf '%s\n' '#!/bin/bash' 'echo called >> "$BRAIN_ROOT/osadecompile.log"' > "$bin/osadecompile"
  printf '%s\n' '#!/bin/bash' 'echo "$*" >> "$BRAIN_ROOT/open.log"' > "$bin/open"
  chmod +x "$bin"/*
  PATH="$bin:$PATH"; export PATH
  CLAUDE_APP="$BRAIN_ROOT/Claude.app"; export CLAUDE_APP
  mkdir -p "$CLAUDE_APP" "$ROOT/Serlinolab_Brain" "$HOME/Desktop"
  APP="$HOME/Applications/Serlino Brain.app"
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/brain_launcher.sh"
}
teardown() { brain_test_teardown; }

url_decode() { printf '%b' "${1//%/\\x}"; }
built_script() { cat "$APP/Contents/Resources/Scripts/main.scpt"; }

@test "a path with spaces and special characters round-trips through the encoding" {
  local path="/Users/Mäx O'Brien & co #1 (100%)/Serlinolab/Serlinolab_Brain" enc
  enc=$(brain_url_encode "$path")
  run grep -q '[^A-Za-z0-9._~%-]' <<<"$enc"
  [ "$status" -ne 0 ]
  [ "$(url_decode "$enc")" = "$path" ]
  [ "$(brain_url_encode 'get started')" = "get%20started" ]
}

@test "the launcher opens Claude on the real Brain folder with get started ready, and lands on the Desktop" {
  ensure_brain_launcher
  local folder
  folder=$(built_script | sed -n 's/.*folder=\([^&]*\)&.*/\1/p')
  [ "$(url_decode "$folder")" = "$(cd "$ROOT/Serlinolab_Brain" && pwd -P)" ]
  built_script | grep -qF "&q=get%20started'\""
  built_script | grep -qF "do shell script \"open 'claude://code/new?folder=%2F"
  [ "$(readlink "$HOME/Desktop/Serlino Brain.app")" = "$APP" ]
  [ ! -e "$BRAIN_ROOT/open.log" ]
}

@test "a second run neither rebuilds nor duplicates the launcher" {
  ensure_brain_launcher
  ensure_brain_launcher
  [ "$(wc -l < "$BRAIN_ROOT/osacompile.log")" -eq 1 ]
  [ "$(find "$HOME/Applications" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]
  [ "$(find "$HOME/Desktop" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]
}

@test "a steady-state cycle neither decompiles nor rebuilds: one attribute read decides" {
  ensure_brain_launcher
  rm -f "$BRAIN_ROOT/osacompile.log"
  ensure_brain_launcher
  [ ! -e "$BRAIN_ROOT/osacompile.log" ]
  [ ! -e "$BRAIN_ROOT/osadecompile.log" ]
  [ "$(xattr -p com.serlinolab.launcher-script "$APP")" = "$(built_script)" ]
  run grep -c "not the launcher this engine builds" "$LOG"
  [ "$output" = 0 ]
}

@test "a launcher that appears at move time is kept, and the temp app never lands inside it" {
  # Stands in for another run winning the gap between the absence re-check and the move: the
  # stubbed mv creates the winner, then BSD mv would put the temp app INSIDE it.
  printf '%s\n' '#!/bin/bash' 'mkdir -p "$RACE_APP/Contents" && echo winner > "$RACE_APP/Contents/winner"' 'exec /bin/mv "$@"' > "$BRAIN_ROOT/bin/mv"
  chmod +x "$BRAIN_ROOT/bin/mv"
  RACE_APP="$APP" ensure_brain_launcher
  [ "$(cat "$APP/Contents/winner")" = winner ]
  [ "$(find "$APP" -mindepth 1 -maxdepth 1)" = "$APP/Contents" ]
  [ -z "$(find "$HOME/Applications" -name '*.building.*')" ]
  grep -q "appeared while building" "$LOG"
}

@test "a missing launcher is recreated, and a Desktop shortcut the person removed stays removed" {
  ensure_brain_launcher
  rm "$HOME/Desktop/Serlino Brain.app"
  ensure_brain_launcher
  [ ! -e "$HOME/Desktop/Serlino Brain.app" ]
  rm -rf "$APP"
  ensure_brain_launcher
  [ "$(wc -l < "$BRAIN_ROOT/osacompile.log")" -eq 2 ]
  [ -f "$APP/Contents/Resources/Scripts/main.scpt" ]
}

@test "an app of the same name the engine did not build is left untouched" {
  mkdir -p "$APP/Contents"; echo mine > "$APP/Contents/keep"
  ensure_brain_launcher
  [ "$(cat "$APP/Contents/keep")" = mine ]
  [ ! -e "$BRAIN_ROOT/osacompile.log" ]
  grep -q "not the launcher this engine builds" "$LOG"
}

@test "with the Claude app not installed, the launcher is skipped and logged, and the sync still succeeds" {
  rm -rf "$CLAUDE_APP"
  run ensure_brain_launcher
  [ "$status" -eq 0 ]
  [ ! -e "$APP" ]
  [ ! -e "$BRAIN_ROOT/osacompile.log" ]
  grep -q "Claude app is not installed" "$LOG"
  rm -rf "$ROOT/Serlinolab_Brain"
  make_fake_team_repo
  make_fake_mirror
  run run_sync_cycle
  [ "$status" -eq 0 ]
  [ ! -e "$APP" ]
}

@test "an already set-up Mac gets the launcher on its next sync cycle" {
  rm -rf "$ROOT/Serlinolab_Brain"
  make_fake_team_repo
  make_fake_mirror   # runs a real sync cycle
  [ -f "$APP/Contents/Resources/Scripts/main.scpt" ]
  [ ! -e "$BRAIN_ROOT/open.log" ]
}

@test "no launcher is built while the Brain folder has not arrived yet" {
  rm -rf "$ROOT/Serlinolab_Brain"
  ensure_brain_launcher
  [ ! -e "$APP" ]
}
