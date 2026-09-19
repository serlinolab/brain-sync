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

@test "mkdir inside a mirror directory fails" {
  run mkdir "$MIRROR/sub/newdir"
  [ "$status" -ne 0 ]
  [ ! -d "$MIRROR/sub/newdir" ]
}
