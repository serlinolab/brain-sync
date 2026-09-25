#!/usr/bin/env bats
# AC-5 - regression: at the 300s cadence an unbounded retry runs ~288
# times a day. The bound must be a named constant, not a buried literal.
#
# 2026-09-25 (Max): a TEXT conflict no longer parks at all - it auto-merges (see
# tests/text_conflict_auto_merge.bats) - so every scenario here that needs to actually stay
# parked across retries uses a BINARY conflict (case 3: park, exactly as before this feature).
load 'helpers'
setup() { brain_test_setup; make_fake_team_repo; }
teardown() { brain_test_teardown; }

make_binary_divergence() {   # a conflict that can never auto-resolve, however many times retried
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  { printf '\x00'; head -c 64 /dev/urandom; } > "$other/note.txt"
  git -C "$other" add note.txt; git_commit "$other" theirs; git -C "$other" push -q origin main
  rm -rf "$other"
  # binary content is compared with cmp against a saved FILE, never via $(cat ...) - a random
  # NUL byte would otherwise silently truncate a bash command substitution.
  { printf '\x00'; head -c 64 /dev/urandom; } > "$BRAIN_ROOT/mine.bin"
  cp "$BRAIN_ROOT/mine.bin" "$TEAM/note.txt"
  git -C "$TEAM" add note.txt; git_commit "$TEAM" mine
}

@test "the conflict-retry bound is a named constant, not a literal" {
  grep -n 'MAX_CONFLICT_ATTEMPTS=[0-9]' "$REPO_ROOT/lib/common.sh"
  grep -n '\-ge "\$MAX_CONFLICT_ATTEMPTS"' "$REPO_ROOT/lib/sync.sh"
}

@test "conflict retries stop after the bound and park with a visible marker, without counting as another attempt" {
  make_binary_divergence
  echo "$MAX_CONFLICT_ATTEMPTS" > "$CONFLICT_STATE"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 3 ]
  [ -f "$MARK" ]
  grep -q "not retrying" "$LOG"
  [ "$(cat "$CONFLICT_STATE")" = "$MAX_CONFLICT_ATTEMPTS" ]

  # Case 7 regression: a BINARY park at the bound can never self-heal, so once this first
  # (always-retried, per the "record missing = changed" rule) attempt has parked again, further
  # cycles with nothing moved must not write another $CONFLICTS copy - the bug filed against
  # PR #6 was exactly this, growing a new copy-dir every 5-minute launchd cycle forever.
  local dirs1; dirs1=$(find "$CONFLICTS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$dirs1" = "1" ]
  for _ in 1 2; do
    ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
    [ "$status" -eq 3 ]
  done
  local dirs2; dirs2=$(find "$CONFLICTS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$dirs2" = "1" ]   # nothing moved: no new conflict copy written

  # Now origin/main actually moves - exactly one new attempt, exactly one new copy-dir.
  sleep 1   # save_conflict_copies dirs are timestamped to the second
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  echo "unrelated change" > "$other/other.txt"
  git -C "$other" add other.txt; git_commit "$other" "unrelated"; git -C "$other" push -q origin main
  rm -rf "$other"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 3 ]
  grep -q "not retrying" "$LOG"
  local dirs3; dirs3=$(find "$CONFLICTS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$dirs3" = "2" ]
}

# Restored after Max lifted the diff cap. The test above seeds the counter at
# the bound; this one never touches it - it makes a real divergence, lets the
# real rebase fail, and checks the counter climbs from nothing and stops.
@test "a real rebase conflict is counted from zero, retained locally, and abandoned at the bound" {
  make_binary_divergence
  [ ! -f "$CONFLICT_STATE" ]

  for n in 1 2 3; do
    ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
    [ "$status" -eq 3 ]
    [ "$(cat "$CONFLICT_STATE")" = "$n" ]
    cmp -s "$TEAM/note.txt" "$BRAIN_ROOT/mine.bin"   # local content never lost
    [ -f "$MARK" ]
  done

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh" # at the bound: park, do not retry
  [ "$status" -eq 3 ]
  [ "$(cat "$CONFLICT_STATE")" = "$MAX_CONFLICT_ATTEMPTS" ]
  grep -q "not retrying" "$LOG"
  [ ! -d "$(git -C "$TEAM" rev-parse --git-path rebase-merge)" ]   # no rebase left hanging

  # Case 7 regression: further cycles with nothing moved must not retry or grow $CONFLICTS.
  local dirs1; dirs1=$(find "$CONFLICTS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 3 ]
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 3 ]
  local dirs2; dirs2=$(find "$CONFLICTS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$dirs2" = "$dirs1" ]

  # Moving origin/main triggers exactly one new attempt and one new copy-dir.
  sleep 1
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  echo "unrelated change" > "$other/other.txt"
  git -C "$other" add other.txt; git_commit "$other" "unrelated"; git -C "$other" push -q origin main
  rm -rf "$other"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 3 ]
  local dirs3; dirs3=$(find "$CONFLICTS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$dirs3" = "$((dirs1 + 1))" ]
}
