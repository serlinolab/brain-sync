#!/usr/bin/env bats
# AC-1
load 'helpers'

setup() {
  BRAIN_ROOT="$(mktemp -d)"; export BRAIN_ROOT
  FAKE_GH_STATE="$(mktemp -d)"; export FAKE_GH_STATE
  GH="$REPO_ROOT/tests/fixtures/fake_gh.sh"; export GH
  BRAIN_ORG="test-org"; export BRAIN_ORG
  LINE="SERLINO-BRAIN-SETUP person=alice machine=alices-mac mirror_key=ssh-ed25519 AAAAmirror brain-mirror-alices-mac team_key=ssh-ed25519 AAAAteam brain-team-alice"
  # The mirror repo is never created by provision.sh (unlike the team repo) - it is assumed to
  # already exist, private, under its real name. Every test gets that baseline for free;
  # a test exercising review fix 5 overwrites this marker to simulate a rename/redirect or a
  # repo gone public.
  mkdir -p "$FAKE_GH_STATE/repos"
  printf 'true\n' > "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain"
}
teardown() { rm -rf "$BRAIN_ROOT" "$FAKE_GH_STATE"; }

repo_exists() { [ -e "$FAKE_GH_STATE/repos/${1//\//__}" ]; }
key_line_count() { wc -l < "$FAKE_GH_STATE/repos/${1//\//__}.keys" 2>/dev/null | tr -d ' '; }

@test "refuses a malformed person slug and makes no gh call" {
  run bash "$REPO_ROOT/provision.sh" "SERLINO-BRAIN-SETUP person=Alice! machine=m mirror_key=ssh-ed25519 AAAA c team_key=ssh-ed25519 AAAA c"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing"* ]] || false
  # only the pre-seeded mirror-repo fixture (setup() bootstraps it as "already exists" - see
  # there) is present; nothing else was added, so no gh call was made
  [ "$(ls -A "$FAKE_GH_STATE/repos" 2>/dev/null)" = "${BRAIN_ORG}__Serlinolab-Brain" ]
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
  [[ "$output" == *"already registered"* ]] || false
  [ "$(key_line_count "$BRAIN_ORG/Serlinolab-Brain")" = 1 ]
  [ "$(key_line_count "$BRAIN_ORG/brain-team")" = 1 ]
}

@test "refuses a title collision with a different key, and changes nothing" {
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -eq 0 ]
  local other="SERLINO-BRAIN-SETUP person=alice machine=alices-mac mirror_key=ssh-ed25519 AAAAdifferent brain-mirror-alices-mac team_key=ssh-ed25519 AAAAteam brain-team-alice"
  run bash "$REPO_ROOT/provision.sh" "$other"
  [ "$status" -ne 0 ]
  [[ "$output" == *"different key"* ]] || false
  [ "$(key_line_count "$BRAIN_ORG/Serlinolab-Brain")" = 1 ]
}

@test "refuses re-registering the same key under a different title" {
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -eq 0 ]
  local other="SERLINO-BRAIN-SETUP person=bob machine=bobs-mac mirror_key=ssh-ed25519 AAAAmirror brain-mirror-alices-mac team_key=ssh-ed25519 AAAAteam2 brain-team-bob"
  run bash "$REPO_ROOT/provision.sh" "$other"
  [ "$status" -ne 0 ]
  [[ "$output" == *"different title"* ]] || false
  [ "$(key_line_count "$BRAIN_ORG/Serlinolab-Brain")" = 1 ]
}

@test "refuses when the deploy-key lookup itself fails, and registers nothing" {
  FAKE_GH_FAIL_KEYS_LOOKUP=1 run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not look up existing deploy keys"* ]] || false
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team" ]
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys" ] || [ -z "$(cat "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys")" ]
}

@test "refuses a read_only mismatch on an already-registered key, and changes nothing" {
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -eq 0 ]
  # flip the mirror key's stored read_only to false by hand, as if it had been mis-registered
  sed -i '' 's/\ttrue$/\tfalse/' "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys" 2>/dev/null \
    || sed -i 's/\ttrue$/\tfalse/' "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys"
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"read_only=false"*"expected read_only=true"* ]] || false
  [ "$(key_line_count "$BRAIN_ORG/Serlinolab-Brain")" = 1 ]
  [ "$(key_line_count "$BRAIN_ORG/brain-team")" = 1 ]   # phase 1 failure - the team key is untouched too
}

@test "paginates the key listing - a key past the fixture's default page size is still recognized as registered" {
  # Seed 30 unrelated keys FIRST, so the real mirror key (registered afterwards) lands past
  # GitHub's real 30-per-page default. Without --paginate the lookup would only see page 1
  # and, finding no match there, would register a SECOND, duplicate row for the same key.
  mkdir -p "$FAKE_GH_STATE/repos"
  local keyfile="$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys"
  for i in $(seq 1 30); do printf 'filler-%s\tssh-ed25519 AAAAfiller%s\tfalse\n' "$i" "$i" >> "$keyfile"; done
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$keyfile" | tr -d ' ')" = 31 ]
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already registered"* ]] || false
  [ "$(wc -l < "$keyfile" | tr -d ' ')" = 31 ]   # not re-registered as a 32nd row
}

@test "recognizes an already-registered key even when the stored copy has no trailing comment" {
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -eq 0 ]
  local keyfile="$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys"
  # strip the trailing comment GitHub does not consider part of the key material
  sed -i '' 's/ brain-mirror-alices-mac\t/\t/' "$keyfile" 2>/dev/null || sed -i 's/ brain-mirror-alices-mac\t/\t/' "$keyfile"
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already registered"* ]] || false
  [ "$(key_line_count "$BRAIN_ORG/Serlinolab-Brain")" = 1 ]
}

@test "retries the initial commit when the team repo exists but was left empty by an interrupted run" {
  # Simulate: `gh repo create --private` succeeded, but the process died before the README PUT.
  mkdir -p "$FAKE_GH_STATE/repos"
  printf 'true\n' > "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team"
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"has no initial commit yet"* ]] || false
  [ -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team.readme" ]
}

@test "--dry-run prints intent and mutates nothing" {
  run bash "$REPO_ROOT/provision.sh" --dry-run "$LINE"
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team" ]
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys" ] || [ -z "$(cat "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys")" ]
}

@test "runs directly as ./provision.sh (executable in git, not just via bash)" {
  cd "$REPO_ROOT" && run ./provision.sh --dry-run "$LINE"
  [ "$status" -eq 0 ]
}

# AC-1a: only a DEFINITE 404 means "absent". Any other failure (5xx, network, auth) refuses
# and changes nothing - never treated as "safe to create".
@test "refuses when the repo-view lookup fails with a 5xx, and creates nothing" {
  FAKE_GH_REPO_VIEW_5XX=1 run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -ne 0 ]
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team" ]
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys" ] || [ -z "$(cat "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys")" ]
}

@test "refuses when the README lookup fails with a 5xx, and writes no initial commit" {
  mkdir -p "$FAKE_GH_STATE/repos"
  printf 'true\n' > "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team"   # repo already exists
  FAKE_GH_README_5XX=1 run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -ne 0 ]
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team.readme" ]
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys" ] || [ -z "$(cat "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys")" ]
}

@test "refuses an existing team repo that is not private, and registers no keys" {
  mkdir -p "$FAKE_GH_STATE/repos"
  printf 'false\n' > "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team"   # exists, but public
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not private"* ]] || false
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys" ] || [ -z "$(cat "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys")" ]
}

# --- Review fix 5: verify identity (full_name) and privacy for BOTH repositories, not just
# the team repo's privacy, before registering any key. ---

@test "refuses a team repo that resolved to a different full_name (renamed or redirected)" {
  mkdir -p "$FAKE_GH_STATE/repos"
  printf 'true\nother-org/brain-team\n' > "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team"
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"renamed or redirected"* ]] || false
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys" ] || [ -z "$(cat "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys")" ]
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team.keys" ] || [ -z "$(cat "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team.keys")" ]
}

@test "refuses a mirror repo that resolved to a different full_name (renamed or redirected), and registers no keys" {
  printf 'true\nother-org/Serlinolab-Brain\n' > "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain"
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"renamed or redirected"* ]] || false
  # review fix 6: every lookup precedes every mutation, so the mirror check refusing means the
  # team repo was never created either, even though the team repo is otherwise fine
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team" ]
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys" ] || [ -z "$(cat "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys")" ]
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team.keys" ] || [ -z "$(cat "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team.keys")" ]
}

@test "refuses a mirror repo that is public, and registers no keys" {
  printf 'false\n' > "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain"
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not private"* ]] || false
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys" ] || [ -z "$(cat "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys")" ]
  # fix 3: phase 1 (the mirror check) fails before phase 2 (which creates the team repo) ever runs
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team" ]
}

# --- fix 3: phase 1 does EVERY read-only check before phase 2 mutates anything. A failure at
# any point in phase 1 - mirror public (above), a team-key lookup 5xx (below), or a team key
# read_only mismatch (above) - must record zero mutations: no team repo created, no README
# written, no key registered on either repo. ---

@test "refuses when the team-key lookup itself 5xxs, and creates nothing - even though the team repo already exists and the mirror check already passed" {
  mkdir -p "$FAKE_GH_STATE/repos"
  printf 'true\n' > "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team"
  touch "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team.readme"
  FAKE_GH_FAIL_KEYS_LOOKUP="brain-team" run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not look up existing deploy keys"* ]] || false
  # the mirror check (and its own key check) ran fine and is not itself the failure, but phase 1
  # as a whole still failed, so its key was never registered either
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys" ] || [ -z "$(cat "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys")" ]
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team.keys" ] || [ -z "$(cat "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team.keys")" ]
}

@test "refuses when the mirror repo does not exist, and registers no keys" {
  rm -f "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain"
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -ne 0 ]
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys" ] || [ -z "$(cat "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys")" ]
}

# --- MAX-1515 fix 1: phase 1 performs every lookup this run needs (including the README-exists
# check on an already-existing team repo, which used to live only in phase 2's ensure_team_repo
# and so was invisible to --dry-run); phase 2 performs only the mutations phase 1 already
# decided on, issuing NO GETs of its own - not even a second deploy-keys lookup to double-check
# what phase 1 already established. ---

@test "phase 2 issues no second deploy-keys GET - a lookup that would only fail on a repeat still lets provisioning succeed" {
  mkdir -p "$FAKE_GH_STATE/repos"
  printf 'true\n' > "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team"
  touch "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team.readme"
  FAKE_GH_KEYS_LOOKUP_FAIL_REPO=brain-team FAKE_GH_KEYS_LOOKUP_FAIL_CALL=2 \
    run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -eq 0 ] || false
  [ "$(cat "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team.keys.get_count")" = 1 ]
  [ "$(key_line_count "$BRAIN_ORG/brain-team")" = 1 ]
}

@test "--dry-run fails when the README lookup 5xxs on an already-existing team repo" {
  # Before fix 1, this check lived only in phase 2's ensure_team_repo, which --dry-run never
  # reaches - a dry run reported success on a repo it could not actually have provisioned.
  mkdir -p "$FAKE_GH_STATE/repos"
  printf 'true\n' > "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team"
  touch "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team.readme"
  FAKE_GH_README_5XX=1 run bash "$REPO_ROOT/provision.sh" --dry-run "$LINE"
  [ "$status" -ne 0 ] || false
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys" ] || [ -z "$(cat "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys")" ]
}

@test "refuses when the team README template is missing, and creates nothing" {
  # A copy of provision.sh with no templates/ beside it: base64 of a missing file used to yield
  # an empty README that was committed while provisioning still reported success.
  local bare; bare="$(mktemp -d)"
  cp "$REPO_ROOT/provision.sh" "$bare/provision.sh"
  run bash "$bare/provision.sh" "$LINE"
  rm -rf "$bare"
  [ "$status" -ne 0 ]
  if repo_exists "$BRAIN_ORG/brain-team"; then false; fi
  [ ! -s "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys" ]
}
