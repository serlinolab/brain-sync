#!/usr/bin/env bats
# AC-1
load 'helpers'

setup() {
  BRAIN_ROOT="$(mktemp -d)"; export BRAIN_ROOT
  FAKE_GH_STATE="$(mktemp -d)"; export FAKE_GH_STATE
  GH="$REPO_ROOT/tests/fixtures/fake_gh.sh"; export GH
  BRAIN_ORG="test-org"; export BRAIN_ORG
  LINE="SERLINO-BRAIN-SETUP person=alice machine=alices-mac mirror_key=ssh-ed25519 AAAAmirror brain-mirror-alices-mac team_key=ssh-ed25519 AAAAteam brain-team-alice"
}
teardown() { rm -rf "$BRAIN_ROOT" "$FAKE_GH_STATE"; }

repo_exists() { [ -e "$FAKE_GH_STATE/repos/${1//\//__}" ]; }
key_line_count() { wc -l < "$FAKE_GH_STATE/repos/${1//\//__}.keys" 2>/dev/null | tr -d ' '; }

@test "refuses a malformed person slug and makes no gh call" {
  run bash "$REPO_ROOT/provision.sh" "SERLINO-BRAIN-SETUP person=Alice! machine=m mirror_key=ssh-ed25519 AAAA c team_key=ssh-ed25519 AAAA c"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing"* ]]
  [ ! -d "$FAKE_GH_STATE/repos" ] || [ -z "$(ls -A "$FAKE_GH_STATE/repos" 2>/dev/null)" ]
}

@test "refuses a malformed machine name" {
  run bash "$REPO_ROOT/provision.sh" "SERLINO-BRAIN-SETUP person=alice machine=bad*mac mirror_key=ssh-ed25519 AAAA c team_key=ssh-ed25519 AAAA c"
  [ "$status" -ne 0 ]
}

@test "refuses a key that does not start with ssh-ed25519" {
  run bash "$REPO_ROOT/provision.sh" "SERLINO-BRAIN-SETUP person=alice machine=m mirror_key=ssh-rsa AAAA c team_key=ssh-ed25519 AAAA c"
  [ "$status" -ne 0 ]
}

@test "creates the team repo and registers both deploy keys on first run" {
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -eq 0 ]
  repo_exists "$BRAIN_ORG/brain-team"
  [ "$(key_line_count "$BRAIN_ORG/Serlinolab-Brain")" = 1 ]
  [ "$(key_line_count "$BRAIN_ORG/brain-team")" = 1 ]
  grep -q $'\ttrue$' "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys"
  grep -q $'\tfalse$' "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team.keys"
}

@test "re-running with the same line is a no-op success, and never creates the repo twice" {
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already registered"* ]]
  [ "$(key_line_count "$BRAIN_ORG/Serlinolab-Brain")" = 1 ]
  [ "$(key_line_count "$BRAIN_ORG/brain-team")" = 1 ]
}

@test "refuses a title collision with a different key, and changes nothing" {
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -eq 0 ]
  local other="SERLINO-BRAIN-SETUP person=alice machine=alices-mac mirror_key=ssh-ed25519 AAAAdifferent brain-mirror-alices-mac team_key=ssh-ed25519 AAAAteam brain-team-alice"
  run bash "$REPO_ROOT/provision.sh" "$other"
  [ "$status" -ne 0 ]
  [[ "$output" == *"different key"* ]]
  [ "$(key_line_count "$BRAIN_ORG/Serlinolab-Brain")" = 1 ]
}

@test "refuses re-registering the same key under a different title" {
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -eq 0 ]
  local other="SERLINO-BRAIN-SETUP person=bob machine=bobs-mac mirror_key=ssh-ed25519 AAAAmirror brain-mirror-alices-mac team_key=ssh-ed25519 AAAAteam2 brain-team-bob"
  run bash "$REPO_ROOT/provision.sh" "$other"
  [ "$status" -ne 0 ]
  [[ "$output" == *"different title"* ]]
  [ "$(key_line_count "$BRAIN_ORG/Serlinolab-Brain")" = 1 ]
}

@test "--dry-run prints intent and mutates nothing" {
  run bash "$REPO_ROOT/provision.sh" --dry-run "$LINE"
  [ "$status" -eq 0 ]
  ! repo_exists "$BRAIN_ORG/brain-team"
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys" ] || [ -z "$(cat "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys")" ]
}
