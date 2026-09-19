#!/usr/bin/env bats
# AC-9 - self-update comes only from brain-sync's own repo, and a new
# version that fails to run must not replace a working one.
load 'helpers'
setup() { brain_test_setup; make_fake_brain_sync_origin; }
teardown() { brain_test_teardown; rm -rf "$BRAIN_SYNC_WORK"; }

@test "an update that fails to run is rolled back to the last working copy, and adoption of a good update is proven along the way" {
  BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" bash "$REPO_ROOT/lib/launcher.sh" --selfcheck-only
  good_sha="$(git -C "$STATE/engine" rev-parse HEAD)"
  run bash "$STATE/engine/sync.sh" --selfcheck
  [ "$status" -eq 0 ]   # the good update was adopted and actually runs

  break_origin_sync_sh
  touch "$STATE/engine/ignored.tmp"
  BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" run bash "$REPO_ROOT/lib/launcher.sh" --selfcheck-only
  [ "$status" -eq 0 ]
  [ "$(git -C "$STATE/engine" rev-parse HEAD)" = "$good_sha" ]
  [ ! -e "$STATE/engine/ignored.tmp" ]
  run bash "$STATE/engine/sync.sh" --selfcheck
  [ "$status" -eq 0 ]
  grep -q "failed selfcheck, restoring" "$LOG"
}

@test "a launcher lock left by a dead pid is taken over" {
  BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" bash "$REPO_ROOT/lib/launcher.sh" --selfcheck-only
  ( sleep 0.1 ) & local deadpid=$!
  wait "$deadpid" 2>/dev/null
  mkdir -p "$STATE/run.lock"; echo "$deadpid" > "$STATE/run.lock/pid"
  BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" run bash "$REPO_ROOT/lib/launcher.sh" --selfcheck-only
  [ "$status" -eq 0 ]
  grep -q "breaking stale lock from pid $deadpid" "$LOG"
}

@test "a launcher holder whose lock was stolen cannot delete the new owner's lock" {
  BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" bash "$REPO_ROOT/lib/launcher.sh" --selfcheck-only
  cat > "$STATE/engine/sync.sh" <<'SCRIPT'
#!/bin/bash
sleep 0.5
SCRIPT
  chmod +x "$STATE/engine/sync.sh"
  BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" bash "$REPO_ROOT/lib/launcher.sh" &
  local holder=$!
  sleep 0.1
  bash -c "echo \$\$ > '$STATE/run.lock/pid'; sleep 2" &
  local owner=$!
  sleep 0.1
  kill -TERM "$holder"
  wait "$holder" || [ "$?" -eq 143 ]
  [ -d "$STATE/run.lock" ]
  [ "$(cat "$STATE/run.lock/pid")" = "$owner" ]
  kill "$owner"
  wait "$owner" || [ "$?" -eq 143 ]
}

@test "the launcher lock prevents two self-update cycles from running together" {
  BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" bash "$REPO_ROOT/lib/launcher.sh" --selfcheck-only
  cat > "$STATE/engine/sync.sh" <<'SCRIPT'
#!/bin/bash
echo run >> "$BRAIN_ROOT/engine-runs"
sleep 0.3
SCRIPT
  chmod +x "$STATE/engine/sync.sh"
  BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" bash "$REPO_ROOT/lib/launcher.sh" &
  local first=$!
  BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" bash "$REPO_ROOT/lib/launcher.sh" &
  local second=$!
  wait "$first"; wait "$second"
  [ "$(wc -l < "$BRAIN_ROOT/engine-runs")" -eq 1 ]
}
