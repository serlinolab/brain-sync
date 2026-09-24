#!/usr/bin/env bats
# Codex review of aea244e, blocking finding 1: `online()` only ever probed the MIRROR's own
# remote (ONLINE_CHECK_REMOTE defaults to EXPECTED_MIRROR_REMOTE), but a single "offline" verdict
# from that ONE probe gated BOTH sync_mirror and sync_team. A mirror-key-only outage (not yet
# registered, revoked, or the mirror host down) therefore blocked team/ from ever syncing, even
# though team/ has its own remote and its own key and was perfectly reachable - exactly the
# shape of the MacBook Air's 13:26 "offline" log line during the 2026-09-24 incident. team/ and
# the mirror must each be probed against THEIR OWN remote, and only skipped independently.
load 'helpers'
setup() { brain_test_setup; make_fake_team_repo; }
teardown() { brain_test_teardown; }

@test "team/ still syncs when only the mirror's remote is unreachable" {
  make_local_ahead_change
  # ONLINE_CHECK_REMOTE (the mirror probe) points nowhere; team/'s own origin (origin-team.git)
  # is untouched and perfectly reachable. No $MIRROR/.git exists in this fixture, so mirror
  # sync is a no-op either way - only team/'s own reachability should decide anything here.
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/no-such-remote" run_sync_cycle
  [ "$(git -C "$TEAM" rev-list --count origin/main..HEAD)" -eq 0 ]
  git -C "$BRAIN_ROOT/origin-team.git" show main:note.txt >/dev/null
  ! grep -q "^offline;" "$LOG"
}

@test "the mirror still syncs when only team/'s remote is unreachable" {
  make_fake_mirror   # runs its own sync cycle to seed the mirror; ignore its outcome here
  rm -f "$LOG"   # start clean for this test's own cycle
  local moved="$BRAIN_ROOT/origin-team.git.moved"
  mv "$BRAIN_ROOT/origin-team.git" "$moved"

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-mirror.git" run bash "$REPO_ROOT/sync.sh"

  mv "$moved" "$BRAIN_ROOT/origin-team.git"
  grep -q "mirror at" "$LOG"
  ! grep -q "^offline;" "$LOG"
  grep -q "team.*unreachable\|team fetch failed" "$LOG"
}

@test "a real full outage (both remotes unreachable) still logs offline and defers, exactly as before" {
  make_local_ahead_change
  local moved="$BRAIN_ROOT/origin-team.git.moved"
  mv "$BRAIN_ROOT/origin-team.git" "$moved"

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/no-such-remote" run_sync_cycle

  mv "$moved" "$BRAIN_ROOT/origin-team.git"
  grep -q "offline; local work is committed" "$LOG"
  [ "$(git -C "$TEAM" rev-list --count origin/main..HEAD)" -eq 1 ]
}
