#!/usr/bin/env bats
# AC-3 - regression: offline work was never committed on the prototype,
# so there was no restore point.
load 'helpers'
setup() { brain_test_setup; make_fake_team_repo; }
teardown() { brain_test_teardown; }

@test "a full cycle with the network unavailable still commits locally, before ever reaching the network" {
  make_local_ahead_change
  run_sync_cycle
  run git -C "$TEAM" log -1 --pretty=%s
  [[ "$output" == notes\ * ]] || false
  [ "$(git -C "$TEAM" rev-list --count origin/main..HEAD)" -eq 1 ]
  grep -q "offline; local work is committed" "$LOG"
}

@test "no network call precedes the local commit in the real entry point" {
  # AC-3 is "before ANY network call", not "before the online guard". Comparing the two line
  # numbers let `online || true` be inserted above commit_local and still pass. Read every
  # line that executes before commit_local instead.
  local at_commit head
  at_commit=$(grep -n '^commit_local$' "$REPO_ROOT/sync.sh" | cut -d: -f1)
  [ -n "$at_commit" ]
  head=$(sed -n "1,$((at_commit - 1))p" "$REPO_ROOT/sync.sh")
  run grep -nE '\bonline\b|fetch|push|pull|clone|ls-remote|curl' <<<"$head"
  [ "$status" -ne 0 ]
}

@test "a commit carries the configured identity, not one git invented from the hostname" {
  # NOT because git fails without a config - measured 2026-09-19, it does not: it derives
  # <user>@<hostname>.local and commits happily. That is the defect. Every creator's notes
  # would be attributed to their Mac's hostname, and MAX-1515 ties attribution to pay.
  make_local_ahead_change
  GIT_AUTHOR_NAME='Wrong Person' GIT_AUTHOR_EMAIL=wrong@example.com \
    GIT_COMMITTER_NAME='Wrong Person' GIT_COMMITTER_EMAIL=wrong@example.com run_sync_cycle
  # the expected value is written out, not read from the engine's own variable: comparing two
  # things the engine computes would pass even when both are wrong. helpers.bash seeds
  # $STATE/person with "testperson", exactly as setup.sh does on a real Mac.
  [ "$(git -C "$TEAM" log -1 --format=%an)" = "Serlino Brain (testperson)" ]
  [[ "$(git -C "$TEAM" log -1 --format=%ae)" == brain-testperson@* ]] || false
  [ "$(git -C "$TEAM" log -1 --format=%cn)" = "Serlino Brain (testperson)" ]
  [[ "$(git -C "$TEAM" log -1 --format=%ce)" == brain-testperson@* ]] || false
}

@test "a foreign push URL is refused before personal notes are pushed" {
  git -C "$TEAM" remote set-url --add --push origin ssh://attacker.invalid/leak.git
  run bash -c "source '$REPO_ROOT/lib/common.sh'; source '$REPO_ROOT/lib/sync.sh'; sync_team"
  [ "$status" -ne 0 ]
  # MAX-1515 fix 4b: remote_matches_expected now catches this before sync_team ever fetches or
  # rebases - a push URL mismatch is one case of an origin not matching EXPECTED_TEAM_REMOTE.
  grep -q "does not match the expected remote" "$LOG"
}
