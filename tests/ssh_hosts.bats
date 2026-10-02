#!/usr/bin/env bats
# Max's Mac Studio (2026-10-01 → 2026-10-02): something rewrote ~/.ssh/config and dropped the
# `Host brain-mirror` / `Host brain-team` blocks setup.sh had written. Both keys were still on
# disk, both deploy keys still registered, yet every cycle for 22 hours logged "offline" -
# the alias no longer resolved, so both probes failed and the cycle took that for no network.
# The engine now re-asserts the two blocks every cycle, but only when the matching key file
# exists: a block pointing at a key that is not there is noise, and setup.sh owns key creation.
load 'helpers'
setup() { brain_test_setup; mkdir -p "$HOME/.ssh"; }
teardown() { brain_test_teardown; }

make_keys() { : > "$HOME/.ssh/brain_mirror_ed25519"; : > "$HOME/.ssh/brain_team_ed25519"; }
host_count() { [ -e "$HOME/.ssh/config" ] || { echo 0; return; }; grep -c "^Host $1\$" "$HOME/.ssh/config" || true; }

@test "a cycle restores both Host blocks when the keys exist and the blocks are gone (the 2026-10-01 incident)" {
  make_keys
  printf 'Host github.com\n  User git' > "$HOME/.ssh/config"   # no trailing newline, like a hand-edited file
  run run_sync_cycle
  [ "$(host_count brain-mirror)" -eq 1 ]
  [ "$(host_count brain-team)" -eq 1 ]
  grep -q "IdentityFile \"$HOME/.ssh/brain_mirror_ed25519\"" "$HOME/.ssh/config"
  grep -q "IdentityFile \"$HOME/.ssh/brain_team_ed25519\"" "$HOME/.ssh/config"
  # the existing content is intact and the first block starts on its own line
  [ "$(sed -n 1p "$HOME/.ssh/config")" = "Host github.com" ]
  [ "$(sed -n 2p "$HOME/.ssh/config")" = "  User git" ]
  [ "$(sed -n 3p "$HOME/.ssh/config")" = "Host brain-mirror" ]
  [ "$(stat -f %Lp "$HOME/.ssh/config")" = "600" ]
  grep -q "restored .*brain-mirror.*brain-team" "$LOG"
}

@test "a present block is left byte-identical and nothing is logged" {
  make_keys
  run run_sync_cycle
  cp "$HOME/.ssh/config" "$BRAIN_ROOT/config.before"
  : > "$LOG"
  run run_sync_cycle
  cmp -s "$HOME/.ssh/config" "$BRAIN_ROOT/config.before"
  ! grep -q "restored" "$LOG"
}

@test "no key, no block: a Mac that never ran setup gets no ssh config written" {
  run run_sync_cycle
  [ ! -e "$HOME/.ssh/config" ]
  ! grep -q "restored" "$LOG"
}

@test "only the block whose key exists is restored" {
  : > "$HOME/.ssh/brain_team_ed25519"
  run run_sync_cycle
  [ "$(host_count brain-team)" -eq 1 ]
  [ "$(host_count brain-mirror)" -eq 0 ]
}

@test "an unwritable ~/.ssh/config is reported once in the log's own format, and the cycle continues" {
  make_keys
  printf 'Host github.com\n' > "$HOME/.ssh/config"; chmod 400 "$HOME/.ssh/config"
  run run_sync_cycle
  chmod 600 "$HOME/.ssh/config"
  grep -q "could not restore ~/.ssh/config Host blocks; continuing" "$LOG"
  ! grep -q "Permission denied" "$LOG"
  ! grep -q "restored ~/.ssh/config" "$LOG"
  # the cycle went on to its network step instead of stopping here
  grep -qE "offline|unreachable|mirror at|team at" "$LOG"
}

@test "the engine's append_host is an identical copy of setup.sh's (comments aside)" {
  body() { sed -n '/^append_host() {$/,/^}$/p' "$1" | grep -v '^[[:space:]]*#'; }
  diff <(body "$REPO_ROOT/setup.sh") <(body "$REPO_ROOT/lib/common.sh")
}
