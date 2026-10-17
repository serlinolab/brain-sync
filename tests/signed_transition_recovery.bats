#!/usr/bin/env bats
load 'helpers'
setup() {
  brain_test_setup
  make_fake_brain_sync_origin
  export BRAIN_SYNC_REMOTE="$FAKE_ORIGIN"
  bash "$TEST_LAUNCHER" --selfcheck-only
  GOOD=$(git -C "$STATE/engine" rev-parse HEAD)
}
teardown() { brain_test_teardown; rm -rf "$BRAIN_SYNC_WORK"; }

@test "REPRO: trust installed by setup, legacy launcher still installed, moves engine-verified past anchor" {
  # Setup-like state: trust anchor GOOD, engine-verified GOOD; but legacy launcher remains (setup exited early)
  cp "$REPO_ROOT/tests/fixtures/legacy_launcher.sh" "$STATE/launcher.sh"
  echo 'echo two >/dev/null' >> "$BRAIN_SYNC_WORK/lib/common.sh"
  git -C "$BRAIN_SYNC_WORK" add -A; git_commit "$BRAIN_SYNC_WORK" S2
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  S2=$(git -C "$BRAIN_SYNC_WORK" rev-parse HEAD)
  bash "$STATE/launcher.sh"            # legacy cycle
  [ "$(cat "$STATE/engine-verified")" = "$S2" ]
  cp "$TEST_LAUNCHER" "$STATE/launcher.sh"   # what S2's ensure_launcher_current would do
  echo 'echo three >/dev/null' >> "$BRAIN_SYNC_WORK/lib/common.sh"
  git -C "$BRAIN_SYNC_WORK" add -A; git_commit "$BRAIN_SYNC_WORK" S3
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  S3=$(git -C "$BRAIN_SYNC_WORK" rev-parse HEAD)
  for i in 1 2 3; do
    run bash "$STATE/launcher.sh"
    [ "$status" -eq 0 ]
    [ "$(cat "$STATE/engine-verified")" = "$S3" ]
    [ "$(git -C "$STATE/engine" rev-parse HEAD)" = "$S3" ]
    grep -qx "# signed-anchor: $S3" "$STATE/update-trust/allowed_signers"
  done
}

@test "unsigned working marker still fetches and adopts a signed repair" {
  git -C "$BRAIN_SYNC_WORK" -c commit.gpgsign=false -c user.name=test -c user.email=test@example.com commit --allow-empty -qm unsigned
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  cp "$REPO_ROOT/tests/fixtures/legacy_launcher.sh" "$STATE/launcher.sh"
  bash "$STATE/launcher.sh"
  unsigned=$(cat "$STATE/engine-verified")
  [ "$unsigned" != "$GOOD" ]
  git -C "$BRAIN_SYNC_WORK" -c user.name=test -c user.email=test@example.com commit --allow-empty -qm repair
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  run bash "$TEST_LAUNCHER"
  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/engine-verified")" = "$(git -C "$BRAIN_SYNC_WORK" rev-parse HEAD)" ]
}

@test "without a working release rejected and offline cycles publish a problem and later recover" {
  make_fake_team_repo
  printf 'test-machine\n' > "$STATE/machine-id"
  before=$(git -C "$TEAM" rev-parse HEAD)
  # Hooks may source the untrusted engine: the emergency heartbeat must never run them.
  printf '#!/bin/bash\ntouch "$BRAIN_ROOT/untrusted-hook-ran"\nexit 1\n' > "$TEAM/.git/hooks/pre-push"
  printf '#!/bin/bash\ntouch "$BRAIN_ROOT/untrusted-engine-ran"\nexit 0\n' > "$BRAIN_SYNC_WORK/sync.sh"
  git -C "$BRAIN_SYNC_WORK" add -A
  git -C "$BRAIN_SYNC_WORK" -c commit.gpgsign=false -c user.name=test -c user.email=test@example.com commit -qm unsigned
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  git -C "$STATE/engine" fetch -q origin main
  git -C "$STATE/engine" reset -q --hard FETCH_HEAD
  git -C "$STATE/engine" rev-parse HEAD > "$STATE/engine-verified"
  for mode in rejected offline selfcheck; do
    case "$mode" in
      offline) mv "$FAKE_ORIGIN" "$FAKE_ORIGIN.offline" ;;
      selfcheck)
        mv "$FAKE_ORIGIN.offline" "$FAKE_ORIGIN"
        break_origin_sync_sh ;;
    esac
    rm -f "$STATE/heartbeat-last"
    run bash "$TEST_LAUNCHER"
    [ "$status" -eq 1 ]
    [ -f "$STATE/heartbeat-last" ]
    [ ! -e "$BRAIN_ROOT/untrusted-engine-ran" ]
    [ ! -e "$BRAIN_ROOT/untrusted-hook-ran" ]
    [ "$(git -C "$TEAM" rev-parse HEAD)" = "$before" ]
    git -C "$BRAIN_ROOT/origin-team.git" show status/testperson-test-machine:status.txt > "$HOME/status"
    grep -qx 'signed updates: problem' "$HOME/status"
    grep -q '^result: problem - self-update: no authenticated working release' "$HOME/status"
    anchor=$(sed -n 's/^# signed-anchor: //p' "$STATE/update-trust/allowed_signers")
    grep -qx "signed anchor: $anchor" "$HOME/status"
  done
  printf '#!/bin/bash\n[ "${1:-}" = --selfcheck ] && exit 0\ntouch "$BRAIN_ROOT/repaired-ran"\n' > "$BRAIN_SYNC_WORK/sync.sh"
  git -C "$BRAIN_SYNC_WORK" add -A; git_commit "$BRAIN_SYNC_WORK" repair
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  run bash "$TEST_LAUNCHER"
  [ "$status" -eq 0 ]
  [ -e "$BRAIN_ROOT/repaired-ran" ]
  [ "$(cat "$STATE/engine-verified")" = "$(git -C "$BRAIN_SYNC_WORK" rev-parse HEAD)" ]
}
