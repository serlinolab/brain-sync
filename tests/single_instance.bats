#!/usr/bin/env bats
# AC-4 - only one cycle runs at a time, and a lock left by a process that
# is no longer alive must not block every cycle after it.
load 'helpers'
setup() { brain_test_setup; }
teardown() { brain_test_teardown; }

@test "exactly one of three concurrent cycles proceeds" {
  for i in 1 2 3; do
    ( bash "$REPO_ROOT/tests/fixtures/lockrunner.sh" 0.5; echo $? > "$BRAIN_ROOT/rc_$i" ) &
  done
  wait
  [ "$(grep -c 'offline; local work' "$LOG")" -eq 1 ]
}

@test "a lock left by a dead pid is broken rather than waited on forever" {
  ( sleep 0.1 ) & local deadpid=$!
  wait "$deadpid" 2>/dev/null
  mkdir -p "$LOCK"; echo "$deadpid" > "$LOCK/pid"
  run bash "$REPO_ROOT/tests/fixtures/lockrunner.sh" 0
  [ "$status" -eq 0 ]
  grep -q "breaking stale lock from pid $deadpid" "$LOG"
}

@test "stale-lock takeover recreates the lock for the winner" {
  ( sleep 0.1 ) & local deadpid=$!
  wait "$deadpid" 2>/dev/null
  mkdir -p "$LOCK"; echo "$deadpid" > "$LOCK/pid"
  bash -c "source '$REPO_ROOT/lib/common.sh'; acquire_lock; sleep 0.5" &
  local winner=$!
  sleep 0.1
  [ -d "$LOCK" ]
  [ "$(cat "$LOCK/pid")" = "$winner" ]
  run bash -c "source '$REPO_ROOT/lib/common.sh'; acquire_lock"
  [ "$status" -ne 0 ]
  wait "$winner"
}
