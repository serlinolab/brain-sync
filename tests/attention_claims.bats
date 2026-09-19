#!/usr/bin/env bats
# AC-7 - the attention file must never claim something the code has not
# just evaluated. Each test ties a claim to a real evaluated condition.
load 'helpers'
setup() { brain_test_setup; make_fake_personal_repo; }
teardown() { brain_test_teardown; }

@test "a resolved conflict marker is removed, not left claiming a problem that no longer exists" {
  echo "stale claim from a previous cycle" > "$MARK"
  run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$MARK" ]
}

@test "the oversize claim is only written, and only names the real file, when one actually exceeds the limit" {
  echo "small note" > "$PERSONAL/note.txt"
  run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$MARK" ]
  ! grep -q REJECT "$LOG"

  dd if=/dev/zero of="$PERSONAL/huge.bin" bs=1024 count=10241 2>/dev/null
  run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  grep -q "huge.bin" "$MARK"
  run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  grep -q "huge.bin" "$MARK"
  rm "$PERSONAL/huge.bin"
  run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$MARK" ]
}
