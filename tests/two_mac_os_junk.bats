#!/usr/bin/env bats
# 2026-09-24 live incident, end-to-end reproduction with two real clones of one bare remote
# (Max's Mac and the MacBook Air), each with its own .DS_Store being rewritten on every cycle
# (Finder's actual behaviour). Expected, per the incident writeup: the first push wins; a
# genuine same-line conflict on the second Mac still parks (AC-6, unchanged) and keeps both
# versions; a non-conflicting two-Mac edit lands cleanly on both sides. In every case,
# .DS_Store must never reach the shared remote.
load 'helpers'
setup() { brain_test_setup; make_fake_team_repo; setup_second_team_clone; }
teardown() { brain_test_teardown; rm -rf "$ROOT2"; }

dirty_finder_junk() {   # $1 = team dir, $2 = content - simulates Finder rewriting .DS_Store
  echo "$2" > "$1/.DS_Store"
}

no_ds_store_ever_reached_origin() {
  local hits
  hits=$(git -C "$BRAIN_ROOT/origin-team.git" log --all --name-only --pretty=format: -- ':(glob)**/.DS_Store' 2>/dev/null | sed '/^$/d')
  [ -z "$hits" ]
}

@test "two-way conflict test: first push wins, the second Mac parks a genuine conflict, no .DS_Store ever reaches the remote" {
  dirty_finder_junk "$TEAM" "mac1 finder bytes"
  echo "mac1 line" > "$TEAM/note.txt"
  git -C "$TEAM" add -A; git_commit "$TEAM" "mac1 edit"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  git -C "$BRAIN_ROOT/origin-team.git" show main:note.txt | grep -q "mac1 line"

  dirty_finder_junk "$TEAM2" "mac2 finder bytes"
  echo "mac2 line" > "$TEAM2/note.txt"
  git -C "$TEAM2" add -A; git_commit "$TEAM2" "mac2 edit"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run run_second_mac_sync_cycle
  [ "$status" -eq 3 ]   # genuine conflict, correctly parked (AC-6 behaviour, unchanged)

  [ "$(cat "$TEAM2/note.txt")" = "mac2 line" ]   # local content retained on the second Mac
  local saved; saved=$(find "$STATE2/conflicts" -name note.txt 2>/dev/null | head -1)
  [ -n "$saved" ]
  [ "$(cat "$saved")" = "mac1 line" ]            # the incoming version was saved, not lost
  grep -q "changed by you and by a colleague" "$ROOT2/SOMETHING NEEDS YOUR ATTENTION.txt"
  git -C "$BRAIN_ROOT/origin-team.git" show main:note.txt | grep -q "mac1 line"   # remote untouched by the loser

  no_ds_store_ever_reached_origin
  ! git -C "$TEAM" ls-files --error-unmatch .DS_Store >/dev/null 2>&1
  ! git -C "$TEAM2" ls-files --error-unmatch .DS_Store >/dev/null 2>&1
}

@test "two-way non-conflicting edit: both Macs' changes land, nothing is parked, and .DS_Store never reaches the remote" {
  dirty_finder_junk "$TEAM" "mac1 finder bytes"
  echo "mac1 content" > "$TEAM/mac1.txt"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]

  dirty_finder_junk "$TEAM2" "mac2 finder bytes"
  echo "mac2 content" > "$TEAM2/mac2.txt"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run run_second_mac_sync_cycle
  [ "$status" -eq 0 ]

  # a further cycle on Mac1 pulls Mac2's change down too
  dirty_finder_junk "$TEAM" "mac1 finder bytes again"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]

  [ "$(cat "$TEAM/mac1.txt")" = "mac1 content" ]
  [ "$(cat "$TEAM/mac2.txt")" = "mac2 content" ]
  git -C "$BRAIN_ROOT/origin-team.git" show main:mac1.txt | grep -q "mac1 content"
  git -C "$BRAIN_ROOT/origin-team.git" show main:mac2.txt | grep -q "mac2 content"
  [ ! -f "$CONFLICT_STATE" ]
  [ ! -f "$STATE2/conflict_attempts" ]
  [ ! -f "$MARK" ]
  [ ! -f "$ROOT2/SOMETHING NEEDS YOUR ATTENTION.txt" ]

  no_ds_store_ever_reached_origin
}
