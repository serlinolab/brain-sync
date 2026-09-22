#!/usr/bin/env bats
# AC-5 - regression: at the 300s cadence an unbounded retry runs ~288
# times a day. The bound must be a named constant, not a buried literal.
load 'helpers'
setup() { brain_test_setup; make_fake_team_repo; }
teardown() { brain_test_teardown; }

@test "the conflict-retry bound is a named constant, not a literal" {
  grep -n 'MAX_CONFLICT_ATTEMPTS=[0-9]' "$REPO_ROOT/lib/common.sh"
  grep -n '\-ge "\$MAX_CONFLICT_ATTEMPTS"' "$REPO_ROOT/lib/sync.sh"
}

@test "conflict retries stop after the bound and park with a visible marker, without counting as another attempt" {
  echo "$MAX_CONFLICT_ATTEMPTS" > "$CONFLICT_STATE"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 3 ]
  [ -f "$MARK" ]
  grep -q "not retrying" "$LOG"
  [ "$(cat "$CONFLICT_STATE")" = "$MAX_CONFLICT_ATTEMPTS" ]
}

# Restored after Max lifted the diff cap. The test above seeds the counter at
# the bound; this one never touches it - it makes a real divergence, lets the
# real rebase fail, and checks the counter climbs from nothing and stops.
make_real_divergence() {
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  echo "the team's line" > "$other/note.txt"
  git -C "$other" add note.txt; git_commit "$other" theirs; git -C "$other" push -q origin main
  rm -rf "$other"
  echo "my line" > "$TEAM/note.txt"
  git -C "$TEAM" add note.txt; git_commit "$TEAM" mine
}

@test "a real rebase conflict is counted from zero, retained locally, and abandoned at the bound" {
  make_real_divergence
  [ ! -f "$CONFLICT_STATE" ]

  for n in 1 2 3; do
    ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
    [ "$status" -eq 3 ]
    [ "$(cat "$CONFLICT_STATE")" = "$n" ]
    [ "$(cat "$TEAM/note.txt")" = "my line" ]   # local content never lost
    [ -f "$MARK" ]
  done

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh" # at the bound: park, do not retry
  [ "$status" -eq 3 ]
  [ "$(cat "$CONFLICT_STATE")" = "$MAX_CONFLICT_ATTEMPTS" ]
  grep -q "not retrying" "$LOG"
  [ ! -d "$(git -C "$TEAM" rev-parse --git-path rebase-merge)" ]   # no rebase left hanging
}
