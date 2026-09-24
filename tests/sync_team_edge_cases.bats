#!/usr/bin/env bats
# Codex review of aea244e, blocking finding 3 and non-blocking finding 6.
load 'helpers'
setup() { brain_test_setup; make_fake_team_repo; }
teardown() { brain_test_teardown; }

@test "a genuine same-line conflict plus junk in local history stays parked; both versions are kept and the attention file is raised" {
  # colleague pushes a conflicting edit to the SAME line
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  echo "the team's line" > "$other/note.txt"
  git -C "$other" add note.txt; git_commit "$other" theirs
  git -C "$other" push -q origin main
  rm -rf "$other"

  # our own unpushed history: a real, conflicting edit PLUS tracked junk
  echo "my line" > "$TEAM/note.txt"
  git -C "$TEAM" add note.txt; git_commit "$TEAM" mine
  echo 'junk' > "$TEAM/.DS_Store"; git -C "$TEAM" add -f .DS_Store; git_commit "$TEAM" 'tracked junk too'

  echo "$MAX_CONFLICT_ATTEMPTS" > "$CONFLICT_STATE"   # already parked from a previous cycle

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"

  [ "$status" -eq 3 ]
  [ "$(cat "$CONFLICT_STATE")" = "$MAX_CONFLICT_ATTEMPTS" ]   # latch untouched - never cleared
  [ "$(cat "$TEAM/note.txt")" = "my line" ]                    # local content retained
  git -C "$BRAIN_ROOT/origin-team.git" show main:note.txt | grep -q "the team's line"   # remote untouched
  grep -q "a genuine conflict remains" "$LOG"
  [ -f "$MARK" ]
  ! git -C "$TEAM" ls-files --error-unmatch .DS_Store >/dev/null 2>&1   # junk still cleaned locally though
}

@test "heal_local_junk_history is bounded by a FRESH origin/main, established by THIS cycle's own fetch" {
  # Simulate a clone whose remote-tracking ref has never been established locally yet (a
  # pruned/reset ref, or a clone whose very first fetch hasn't run) - origin/main is UNKNOWN
  # locally until sync_team's own fetch runs. Healing before that fetch (the old ordering) hits
  # heal_local_junk_history's own "origin/main unknown" guard and skips healing entirely -
  # the junk-laden commit then goes out unhealed once the fetch later in the old cycle makes
  # origin/main known just in time to rebase and push, but too late to heal.
  git -C "$TEAM" update-ref -d refs/remotes/origin/main

  echo 'junk' > "$TEAM/.DS_Store"; git -C "$TEAM" add -f .DS_Store
  echo 'a real note' >> "$TEAM/note.txt"
  git -C "$TEAM" add -A; git_commit "$TEAM" 'mine, with junk'

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  git -C "$BRAIN_ROOT/origin-team.git" show main:note.txt | grep -q "a real note"
  ! git -C "$BRAIN_ROOT/origin-team.git" log --all --name-only -- ':(glob)**/.DS_Store' | grep -q DS_Store
}

@test "an autostash pop conflict after a successful rebase is reported clearly, never silently pushed" {
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  echo "colleague content" > "$other/note.txt"
  git -C "$other" add -A; git_commit "$other" colleague
  git -C "$other" push -q origin main
  rm -rf "$other"

  echo "dirty local edit" > "$TEAM/note.txt"   # tracked, dirty, uncommitted - what autostash stashes

  run bash -c "source '$REPO_ROOT/lib/common.sh'; source '$REPO_ROOT/lib/secretscan.sh'; \
    source '$REPO_ROOT/lib/team_layout.sh'; source '$REPO_ROOT/lib/complete_setup.sh'; \
    source '$REPO_ROOT/lib/sync.sh'; ONLINE_CHECK_REMOTE='$BRAIN_ROOT/origin-team.git'; sync_team"

  [ "$status" -ne 0 ]
  grep -q "autostash" "$LOG"
  git -C "$TEAM" stash list | grep -q .   # the conflicting stash is preserved, not silently dropped
  ! git -C "$BRAIN_ROOT/origin-team.git" show main:note.txt | grep -q "<<<<<<<"
}
