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

@test "an abandoned lock is taken over, and age decides it rather than a pid" {
  mkdir -p "$LOCK"
  # No pid file at all - a crash between mkdir and the pid write used to leave a lock nobody
  # could ever break, and every later cycle refused forever. Age does not care.
  touch -t 202001010000 "$LOCK"
  run bash -c "source '$REPO_ROOT/lib/common.sh'; acquire_lock && echo taken"
  [ "$status" -eq 0 ]
  [[ "$output" == *taken* ]] || false
  grep -q "broke a lock abandoned" "$LOG"
}

@test "a fresh lock is never broken, whatever pid it names" {
  mkdir -p "$LOCK"
  echo 999999 > "$LOCK/pid"        # a dead pid, but the lock itself is seconds old
  run bash -c "source '$REPO_ROOT/lib/common.sh'; acquire_lock"
  [ "$status" -ne 0 ]
  [ -d "$LOCK" ]
}

@test "a takeover leaves the lock present and owned by the winner" {
  mkdir -p "$LOCK"; touch -t 202001010000 "$LOCK"
  bash -c "source '$REPO_ROOT/lib/common.sh'; acquire_lock; sleep 0.6" &
  local winner=$!
  sleep 0.2
  [ -d "$LOCK" ]
  [ "$(cat "$LOCK/pid")" = "$winner" ]
  run bash -c "source '$REPO_ROOT/lib/common.sh'; acquire_lock"
  [ "$status" -ne 0 ]
  wait "$winner"
}

@test "the engine and the launcher carry the same lock, byte for byte" {
  # The launcher must not source engine files (a broken update would take down its own
  # rollback), so the lock is duplicated on purpose. Three review rounds broke one copy at a
  # time; this is what stops them drifting apart again.
  run diff <(sed -n '/^LOCK_STALE_SECONDS=/,/^}$/p' "$REPO_ROOT/lib/common.sh") \
           <(sed -n '/^LOCK_STALE_SECONDS=/,/^}$/p' "$REPO_ROOT/lib/launcher.sh")
  [ "$status" -eq 0 ]
}

@test "a holder whose lock was stolen cannot delete the new owner's lock" {
  bash -c "source '$REPO_ROOT/lib/common.sh'; acquire_lock; sleep 0.5" &
  local holder=$!
  sleep 0.1
  bash -c "echo \$\$ > '$LOCK/pid'; sleep 2" &
  local owner=$!
  sleep 0.1
  kill -TERM "$holder"
  wait "$holder" || [ "$?" -eq 143 ]
  [ -d "$LOCK" ]
  [ "$(cat "$LOCK/pid")" = "$owner" ]
  kill "$owner"
  wait "$owner" || [ "$?" -eq 143 ]
}
