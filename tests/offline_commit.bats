#!/usr/bin/env bats
# AC-3 - regression: offline work was never committed on the prototype,
# so there was no restore point.
load 'helpers'
setup() { brain_test_setup; make_fake_personal_repo; }
teardown() { brain_test_teardown; }

@test "a full cycle with the network unavailable still commits locally, before ever reaching the network" {
  make_local_ahead_change
  run_sync_cycle
  run git -C "$PERSONAL" log -1 --pretty=%s
  [[ "$output" == notes\ * ]]
  [ "$(git -C "$PERSONAL" rev-list --count origin/main..HEAD)" -eq 1 ]
  grep -q "offline; local work is committed" "$LOG"
}
