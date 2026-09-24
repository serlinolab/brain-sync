#!/usr/bin/env bats
# AC-6 - team/ syncs two-way. A same-line conflict parks locally, saves the incoming copy,
# and raises a plain-words marker; two edits to different files, and an offline-then-online
# cycle, both sync cleanly.
load 'helpers'
setup() { brain_test_setup; make_fake_team_repo; }
teardown() { brain_test_teardown; }

make_colleague_edit() {   # $1 = filename, $2 = content
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  echo "$2" > "$other/$1"
  git -C "$other" add -A; git_commit "$other" "colleague: $1"
  git -C "$other" push -q origin main
  rm -rf "$other"
}

@test "a same-line conflict parks locally, saves the incoming copy under conflicts/, and the marker uses plain words" {
  make_colleague_edit note.txt "the team's line"
  echo "my line" > "$TEAM/note.txt"
  git -C "$TEAM" add note.txt; git_commit "$TEAM" mine

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"

  [ "$(cat "$TEAM/note.txt")" = "my line" ]   # local content wins on disk
  local saved; saved=$(find "$CONFLICTS" -name note.txt 2>/dev/null | head -1)
  [ -n "$saved" ]
  [ "$(cat "$saved")" = "the team's line" ]
  grep -q "changed by you and by a colleague" "$MARK"
  ! grep -qi 'rebase\|merge\|conflict' "$MARK"   # plain words, no git vocabulary
}

@test "two edits to different files sync cleanly with no conflict" {
  make_colleague_edit other.txt "colleague content"
  echo "my content" > "$TEAM/mine.txt"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run_sync_cycle

  [ "$(cat "$TEAM/mine.txt")" = "my content" ]
  [ "$(cat "$TEAM/other.txt")" = "colleague content" ]
  [ ! -f "$CONFLICT_STATE" ]
  [ ! -f "$MARK" ]
}

@test "a sync cycle against a team clone whose origin was changed to another repo leaves it untouched and raises the marker" {
  # MAX-1515 fix 4b: the engine re-checks team/'s origin every cycle - a swapped origin means
  # no add, no rebase, no push, however innocent the swap.
  git -C "$TEAM" remote set-url origin "$BRAIN_ROOT/some-other-repo.git"
  echo "my note" > "$TEAM/mine.txt"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -ne 0 ]
  git -C "$TEAM" status --porcelain | grep -qF "?? mine.txt"   # never staged
  grep -qi "team" "$MARK"
}

@test "an offline edit reaches the team the moment the network comes back" {
  echo "written offline" > "$TEAM/offline.txt"
  git -C "$TEAM" add -A; git_commit "$TEAM" offline   # commit_local's job in a real cycle; done here for a focused test
  # team_online() (lib/sync.sh) probes team/'s own origin now, not ONLINE_CHECK_REMOTE (the
  # mirror probe) - simulate a genuinely offline Mac by taking team/'s own remote away too.
  simulate_team_remote_down
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/no-such-remote" run_sync_cycle
  restore_team_remote
  [ "$(git -C "$TEAM" rev-list --count origin/main..HEAD)" -eq 1 ]

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run_sync_cycle
  [ "$(git -C "$TEAM" rev-list --count origin/main..HEAD)" -eq 0 ]
  git -C "$BRAIN_ROOT/origin-team.git" show main:offline.txt >/dev/null
}
