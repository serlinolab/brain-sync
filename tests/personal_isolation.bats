#!/usr/bin/env bats
# AC-5 - personal/ never leaves this Mac: no git anywhere under it, the engine never reads or
# writes it, and it never appears in the plist's WatchPaths.
load 'helpers'
setup() { brain_test_setup; make_fake_team_repo; make_fake_mirror; }
teardown() { brain_test_teardown; }

@test "a file saved in personal/ never reaches either remote after a full cycle" {
  mkdir -p "$PERSONAL/ideas"
  echo 'secret plan' > "$PERSONAL/ideas/plan.txt"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run_sync_cycle
  run git -C "$BRAIN_ROOT/origin-team.git" show main --stat
  [[ "$output" != *"plan.txt"* ]]
  run git -C "$BRAIN_ROOT/origin-mirror.git" show main --stat
  [[ "$output" != *"plan.txt"* ]]
  [ ! -d "$PERSONAL/.git" ]
  [ ! -d "$PERSONAL/ideas/.git" ]
}

@test "personal/ is never initialised as a git repository by any part of the engine" {
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run_sync_cycle
  [ ! -d "$PERSONAL/.git" ]
}

@test "the installed plist's WatchPaths names only team/, never personal/" {
  run grep -n 'PERSONAL' "$REPO_ROOT/setup.sh"
  # the only occurrences of PERSONAL left in setup.sh are the personal/ folder scaffolding
  # (mkdir + write_if_absent), never a WatchPaths entry
  [[ "$output" != *WatchPaths* ]]
  run grep -A2 'WatchPaths' "$REPO_ROOT/setup.sh"
  [[ "$output" == *'$TEAM_XML'* ]]
  [[ "$output" != *'personal'* ]]
}
