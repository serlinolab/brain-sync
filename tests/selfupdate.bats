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
  BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" run bash "$REPO_ROOT/lib/launcher.sh" --selfcheck-only
  [ "$status" -eq 0 ]
  [ "$(git -C "$STATE/engine" rev-parse HEAD)" = "$good_sha" ]
  run bash "$STATE/engine/sync.sh" --selfcheck
  [ "$status" -eq 0 ]
  grep -q "failed selfcheck, restoring" "$LOG"
}
