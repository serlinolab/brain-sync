#!/usr/bin/env bats
# AC-2 - regression: mirror directories stayed writable on the prototype,
# so a creator's new file was silently eaten by the next clean.
load 'helpers'
setup() { brain_test_setup; make_fake_mirror; }
teardown() { brain_test_teardown; }

@test "creating a new file inside a mirror directory fails" {
  run bash -c "echo hi > '$MIRROR/sub/newfile.txt'" 2>/dev/null
  [ "$status" -ne 0 ]
  [ ! -e "$MIRROR/sub/newfile.txt" ]
}

@test "creating a new file at the mirror root fails" {
  run bash -c "echo hi > '$MIRROR/root-file.txt'" 2>/dev/null
  [ "$status" -ne 0 ]
  [ ! -e "$MIRROR/root-file.txt" ]
}

@test "a failed mirror fetch leaves the mirror protected" {
  git -C "$MIRROR" remote set-url origin "$BRAIN_ROOT/missing-origin.git"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-mirror.git" run bash "$REPO_ROOT/sync.sh"
  run bash -c "echo hi > '$MIRROR/after-failed-fetch.txt'" 2>/dev/null
  [ "$status" -ne 0 ]
}

@test "mkdir inside a mirror directory fails" {
  run mkdir "$MIRROR/sub/newdir"
  [ "$status" -ne 0 ]
  [ ! -d "$MIRROR/sub/newdir" ]
}
