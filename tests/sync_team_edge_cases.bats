#!/usr/bin/env bats
# Codex review of aea244e, blocking finding 3 and non-blocking finding 6.
load 'helpers'
setup() { brain_test_setup; make_fake_team_repo; }
teardown() { brain_test_teardown; }

@test "a genuine BINARY conflict plus junk in local history stays parked; both versions are kept and the attention file is raised" {
  # colleague pushes a conflicting edit to the SAME file - binary, so it can never auto-merge
  # (2026-09-25, Max: a TEXT same-line conflict no longer parks here - see the "heals" test
  # below, which is this exact same shape with a text file instead)
  # binary content is compared with cmp against saved FILES, never via $(cat ...) - a random
  # NUL byte in the content would otherwise silently truncate a bash command substitution.
  local theirs_file="$BRAIN_ROOT/theirs.bin" mine_file="$BRAIN_ROOT/mine.bin"
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  { printf '\x00'; head -c 64 /dev/urandom; } > "$theirs_file"
  cp "$theirs_file" "$other/note.txt"
  git -C "$other" add note.txt; git_commit "$other" theirs
  git -C "$other" push -q origin main
  rm -rf "$other"

  # our own unpushed history: a real, conflicting edit PLUS tracked junk
  { printf '\x00'; head -c 64 /dev/urandom; } > "$mine_file"
  cp "$mine_file" "$TEAM/note.txt"
  git -C "$TEAM" add note.txt; git_commit "$TEAM" mine
  echo 'junk' > "$TEAM/.DS_Store"; git -C "$TEAM" add -f .DS_Store; git_commit "$TEAM" 'tracked junk too'

  echo "$MAX_CONFLICT_ATTEMPTS" > "$CONFLICT_STATE"   # already parked from a previous cycle

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"

  [ "$status" -eq 3 ]
  [ "$(cat "$CONFLICT_STATE")" = "$MAX_CONFLICT_ATTEMPTS" ]   # latch untouched - never cleared
  cmp -s "$TEAM/note.txt" "$mine_file"                         # local content retained
  git -C "$BRAIN_ROOT/origin-team.git" show main:note.txt > "$BRAIN_ROOT/remote-after.bin"
  cmp -s "$BRAIN_ROOT/remote-after.bin" "$theirs_file"          # remote untouched
  grep -q "a genuine (binary) conflict remains" "$LOG"
  [ -f "$MARK" ]
  ! git -C "$TEAM" ls-files --error-unmatch .DS_Store >/dev/null 2>&1   # junk still cleaned locally though
}

# Case 7: the exact same shape as the test above (parked at the bound, junk in local history),
# but the conflict itself is TEXT - the live 2026-09-24 incident (team/serlinolab-background.md
# on the MacBook Air) is this scenario. Reproduces "healing an existing latch": a Mac already
# sitting at MAX_CONFLICT_ATTEMPTS from before this feature existed must resolve on its very
# next cycle, since a text conflict now always auto-merges.
@test "a Mac parked at the bound by a TEXT-only conflict heals on the next cycle: latch clears, both versions kept, no attention file, and it pushes" {
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  echo "the team's line" > "$other/note.txt"
  git -C "$other" add note.txt; git_commit "$other" theirs
  git -C "$other" push -q origin main
  rm -rf "$other"

  echo "my line" > "$TEAM/note.txt"
  git -C "$TEAM" add note.txt; git_commit "$TEAM" mine

  echo "$MAX_CONFLICT_ATTEMPTS" > "$CONFLICT_STATE"   # parked at the bound from before this fix

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"

  [ "$status" -eq 0 ]
  [ ! -f "$CONFLICT_STATE" ]
  [ ! -f "$MARK" ]
  grep -q "cleared a parked conflict on retry" "$LOG"
  local remote; remote=$(git -C "$BRAIN_ROOT/origin-team.git" show main:note.txt)
  grep -qF "my line" <<<"$remote"
  grep -qF "the team's line" <<<"$remote"
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

@test "an unrelated pre-existing stash never blocks the push" {
  # Codex re-review of 0b5862b: a stash the person made themselves (or one left over from a
  # previous, already-reported autostash conflict) must never be mistaken for THIS cycle's own
  # autostash - only a NEW entry this cycle's own rebase creates and fails to reapply counts.
  echo "pre-existing stash content" > "$TEAM/other.txt"
  git -C "$TEAM" add -A
  git -C "$TEAM" -c user.name=fixture -c user.email=fixture@example.com stash push -q -m "unrelated, made by the person"
  [ -n "$(git -C "$TEAM" stash list)" ]

  echo "a real note" >> "$TEAM/note.txt"
  git -C "$TEAM" add -A; git_commit "$TEAM" mine

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"

  [ "$status" -eq 0 ]
  git -C "$BRAIN_ROOT/origin-team.git" show main:note.txt | grep -q "a real note"
  [ ! -f "$MARK" ]
  [ ! -f "$STATE/autostash_conflict" ]
  # the person's own stash is still exactly there, untouched either way
  git -C "$TEAM" stash list | grep -q "unrelated, made by the person"
}

@test "a genuine autostash pop conflict raises the attention file in plain words and keeps the content" {
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  echo "colleague content" > "$other/note.txt"
  git -C "$other" add -A; git_commit "$other" colleague
  git -C "$other" push -q origin main
  rm -rf "$other"

  echo "dirty local edit" > "$TEAM/note.txt"   # tracked, dirty, uncommitted - what autostash stashes
  # bypasses commit_local on purpose (a full engine cycle would commit this dirty edit before
  # sync_team ever runs, leaving nothing for --autostash to stash) - calls sync_team directly,
  # the same pattern the existing autostash test above uses, then update_attention_marker the
  # same way sync.sh's own entry point does right after.
  run bash -c "source '$REPO_ROOT/lib/common.sh'; source '$REPO_ROOT/lib/secretscan.sh'; \
    source '$REPO_ROOT/lib/team_layout.sh'; source '$REPO_ROOT/lib/complete_setup.sh'; \
    source '$REPO_ROOT/lib/sync.sh'; ONLINE_CHECK_REMOTE='$BRAIN_ROOT/origin-team.git'; \
    sync_team; rc=\$?; update_attention_marker; exit \$rc"

  [ "$status" -ne 0 ]
  [ -f "$STATE/autostash_conflict" ]
  [ -f "$MARK" ]
  ! grep -qi 'rebase\|stash\|autostash\|conflict' "$MARK"   # plain words, no git vocabulary
  grep -q "could not be" "$MARK"
  git -C "$TEAM" stash list | grep -q .   # the person's content is retained, not lost

  # self-heals once a human resolves it for real (AC-7: re-derived, not just a stale flag)
  git -C "$TEAM" stash drop -q
  run bash -c "source '$REPO_ROOT/lib/common.sh'; source '$REPO_ROOT/lib/sync.sh'; update_attention_marker"
  [ ! -f "$STATE/autostash_conflict" ]
  [ ! -f "$MARK" ]
}
