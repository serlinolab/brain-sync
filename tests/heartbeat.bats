#!/usr/bin/env bats
# Max, 2026-10-03: "you must be able to check remotely too". Each Mac publishes a small status file
# to its own branch `status/<person>-<machine>` in brain-team (force-pushed, never touching main or
# the team/ working tree), on a change of result or at least hourly. ./fleet-status.sh reads them.
# A Mac whose cycles stop simply stops publishing - its age IS the signal.
load 'helpers'
setup() {
  brain_test_setup
  make_fake_team_repo
  make_fake_mirror                                   # this first cycle already publishes
  MACHINE=$(cat "$STATE/machine-id"); BRANCH="status/testperson-$MACHINE"
}
teardown() { brain_test_teardown; }

origin() { git -C "$BRAIN_ROOT/origin-team.git" "$@"; }
status_file() { origin show "$BRANCH:status.txt"; }
tip() { origin rev-parse --verify -q "refs/heads/$BRANCH"; }

@test "a healthy cycle publishes this Mac's status to its own branch, and nothing else changes" {
  local main_before head_before index_before refs_before tip_before
  main_before=$(origin rev-parse main); tip_before=$(tip)
  head_before=$(git -C "$TEAM" rev-parse HEAD); index_before=$(git -C "$TEAM" rev-parse :note.txt)
  refs_before=$(git -C "$TEAM" for-each-ref --format='%(refname)' refs/heads)
  HEARTBEAT_INTERVAL_SECONDS=0 run_sync_cycle            # a publish inside THIS test
  [ "$(tip)" != "$tip_before" ]
  status_file | grep -qx "person: testperson"
  status_file | grep -qx "machine: $MACHINE"
  status_file | grep -qx "result: ok"
  status_file | grep -q "^engine: "
  status_file | grep -q "^updated: 20"
  status_file | grep -q "^--- last 20 lines of sync.log"
  status_file | grep -q "team at "
  [ "$(origin rev-parse main)" = "$main_before" ]                                   # main untouched
  [ -z "$(git -C "$TEAM" status --porcelain)" ]                                     # working tree untouched
  [ "$(git -C "$TEAM" rev-parse HEAD)" = "$head_before" ]                            # HEAD untouched
  [ "$(git -C "$TEAM" rev-parse :note.txt)" = "$index_before" ]                       # index untouched
  [ "$(git -C "$TEAM" for-each-ref --format='%(refname)' refs/heads)" = "$refs_before" ]   # no local branch
  [ "$(origin ls-tree --name-only "$BRANCH")" = "status.txt" ]                      # one file only
}

@test "the same result within the hour is not published again" {
  run_sync_cycle
  local first; first=$(tip)
  run_sync_cycle
  [ "$(tip)" = "$first" ]
}

@test "after the interval it is published again, as a single fresh commit (no history grows)" {
  local first; first=$(tip)
  HEARTBEAT_INTERVAL_SECONDS=0 run_sync_cycle
  [ "$(tip)" != "$first" ]
  [ "$(origin rev-list --count "$BRANCH")" -eq 1 ]
}

@test "a change of result is published at once" {
  run_sync_cycle
  local first; first=$(tip)
  mv "$BRAIN_ROOT/origin-mirror.git" "$BRAIN_ROOT/origin-mirror.git.moved"   # mirror down, team still up
  run run_sync_cycle
  [ "$(tip)" != "$first" ]
  status_file | grep -qx "result: problem - mirror unreachable"
}

@test "nothing from personal/ ever reaches the status" {
  mkdir -p "$PERSONAL"; echo "PRIVATE-MARKER-7731" > "$PERSONAL/secret-plan.md"
  printf '%s a line mentioning personal/secret-plan.md\n' "$(date -u +%FT%TZ)" >> "$LOG"   # even if a log line names it
  # setup's cycle already published; force a fresh one so the assertion sees THIS content.
  HEARTBEAT_INTERVAL_SECONDS=0 run_sync_cycle
  if status_file | grep -q "PRIVATE-MARKER-7731"; then false; fi
}

@test "ordinary log lines with commit hashes pass the team's secret scan" {
  printf '%s self-update: updated 382ecae1350f953f3c36ac9a7ed0b7c42a6ab9d9 -> ed4034b4291dead86084e158409302747bdbd3ae\n' "$(date -u +%FT%TZ)" >> "$LOG"
  # setup's cycle already published; force a fresh one so the assertion sees THIS content.
  HEARTBEAT_INTERVAL_SECONDS=0 run_sync_cycle
  status_file | grep -q "self-update: updated 382ecae"
}

@test "a status push that fails never fails the cycle, and is logged once" {
  HEARTBEAT_REMOTE="$BRAIN_ROOT/no-such-remote.git"; export HEARTBEAT_REMOTE
  HEARTBEAT_INTERVAL_SECONDS=0 run run_sync_cycle      # two real attempts, both failing
  HEARTBEAT_INTERVAL_SECONDS=0 run run_sync_cycle
  [ "$(grep -c "could not publish this Mac's status" "$LOG")" -eq 1 ]
  grep -q "team at " "$LOG"
}

@test "a status that looks like it holds a secret is refused by the team's scan and never reaches GitHub" {
  printf '%s git said: token ghp_abcdefghijklmnopqrstuvwxyz0123456789AB\n' "$(date -u +%FT%TZ)" >> "$LOG"
  local before; before=$(tip)
  HEARTBEAT_INTERVAL_SECONDS=0 run run_sync_cycle
  [ "$status" -eq 0 ]
  [ "$(tip)" = "$before" ]
  if status_file | grep -q "ghp_"; then false; fi
  grep -q "could not publish this Mac's status.*secret" "$LOG"
}

@test "the machine name is stored once and stays the same when the hostname changes" {
  local first; first=$(cat "$STATE/machine-id")
  [[ "$first" =~ ^[A-Za-z0-9._-]+-[0-9a-f]{4}$ ]] || false
  HEARTBEAT_INTERVAL_SECONDS=0 run_sync_cycle
  [ "$(cat "$STATE/machine-id")" = "$first" ]
}

# --- fleet-status.sh (run by Max, or by Claude for him) -------------------------------------------

@test "fleet-status lists every Mac with its result and how old its status is" {
  run_sync_cycle
  FLEET_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/fleet-status.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"testperson-$MACHINE"* ]] || false
  [[ "$output" == *"ok"* ]] || false
  [[ "$output" == *"min ago"* || "$output" == *"just now"* ]] || false
}

@test "fleet-status flags a Mac whose status stopped updating" {
  run_sync_cycle
  # Re-publish an old timestamp, as a Mac stuck since then would have left it.
  local f="$BRAIN_ROOT/old.txt"; status_file | sed 's/^updated: .*/updated: 2026-01-01T00:00:00Z/' > "$f"
  local blob tree commit
  blob=$(origin hash-object -w "$f"); tree=$(printf '100644 blob %s\tstatus.txt\n' "$blob" | origin mktree)
  commit=$(origin -c user.name=t -c user.email=t@t commit-tree "$tree" -m old); origin update-ref "refs/heads/$BRANCH" "$commit"
  FLEET_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/fleet-status.sh"
  [[ "$output" == *"STALE"* ]] || false
}

@test "fleet-status --full shows one Mac's whole status, log included" {
  run_sync_cycle
  FLEET_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/fleet-status.sh" --full "testperson-$MACHINE"
  [[ "$output" == *"--- last 20 lines of sync.log"* ]] || false
}
