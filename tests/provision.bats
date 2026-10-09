#!/usr/bin/env bats
# AC-1
load 'helpers'

setup() {
  BRAIN_ROOT="$(mktemp -d)"; export BRAIN_ROOT
  FAKE_GH_STATE="$(mktemp -d)"; export FAKE_GH_STATE
  BRAIN_PROVISION_STATE="$BRAIN_ROOT/provision-state"; export BRAIN_PROVISION_STATE   # never the real home
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
  # MAX-1790: the Brain key is registered WITH write access now (it was read-only before)
  grep -q $'\tfalse$' "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys"
  ! grep -q $'\ttrue$' "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys" || false
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

@test "refuses a read_only mismatch on an already-registered team key, and changes nothing" {
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -eq 0 ]
  # flip the team key's stored read_only to true by hand, as if it had been mis-registered
  sed -i '' 's/\tfalse$/\ttrue/' "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team.keys" 2>/dev/null \
    || sed -i 's/\tfalse$/\ttrue/' "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team.keys"
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"read_only=true"*"expected read_only=false"* ]] || false
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

@test "refuses an unreadable README template before creating anything" {
  local bare; bare="$(mktemp -d)"
  cp "$REPO_ROOT/provision.sh" "$bare/provision.sh"
  mkdir "$bare/templates"; echo "readme" > "$bare/templates/team-repo-README.md"
  chmod 000 "$bare/templates/team-repo-README.md"
  run bash "$bare/provision.sh" "$LINE"
  chmod 644 "$bare/templates/team-repo-README.md"; rm -rf "$bare"
  [ "$status" -ne 0 ]
  if repo_exists "$BRAIN_ORG/brain-team"; then false; fi
  [ ! -s "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys" ]
}

@test "refuses when encoding the README template fails part-way, in a real run and in --dry-run" {
  # A base64 that prints partial output and then fails must not pass as a valid README.
  local shim; shim="$(mktemp -d)"
  printf '#!/bin/bash\nprintf cGFydGlhbA==\nexit 1\n' > "$shim/base64"; chmod +x "$shim/base64"
  PATH="$shim:$PATH" run bash "$REPO_ROOT/provision.sh" --dry-run "$LINE"
  local dry_status=$status
  PATH="$shim:$PATH" run bash "$REPO_ROOT/provision.sh" "$LINE"
  rm -rf "$shim"
  [ "$dry_status" -ne 0 ]
  [ "$status" -ne 0 ]
  if repo_exists "$BRAIN_ORG/brain-team"; then false; fi
  [ ! -s "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys" ]
}

# --- MAX-1790: the Brain key is writable; an existing read-only one is upgraded, nothing else is ---

BRAIN_KEYS() { printf '%s' "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain.keys"; }
# a Mac provisioned before MAX-1790: a read-only Brain key, with another Mac's key ahead of it
seed_readonly_brain_key() {
  printf 'brain-mirror bob bobs-mac\tssh-ed25519 AAAAother brain-mirror-bobs-mac\ttrue\n' > "$(BRAIN_KEYS)"
  printf 'brain-mirror alice alices-mac\tssh-ed25519 AAAAmirror brain-mirror-alices-mac\ttrue\n' >> "$(BRAIN_KEYS)"
}

@test "re-running a Mac's pasted line upgrades its read-only Brain key to write access, same key and title" {
  seed_readonly_brain_key
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"upgrade"* ]] || false
  [ "$(key_line_count "$BRAIN_ORG/Serlinolab-Brain")" = 2 ]
  grep -qF $'brain-mirror bob bobs-mac\tssh-ed25519 AAAAother brain-mirror-bobs-mac\ttrue' "$(BRAIN_KEYS)"   # bob's key untouched
  awk -F'\t' '$1=="brain-mirror alice alices-mac" && $2 ~ /^ssh-ed25519 AAAAmirror/ && $3=="false"{f=1} END{exit !f}' "$(BRAIN_KEYS)"
  [ "$(key_line_count "$BRAIN_ORG/brain-team")" = 1 ]
  run bash "$REPO_ROOT/provision.sh" "$LINE"            # and it is idempotent
  [ "$status" -eq 0 ]
  [[ "$output" == *"already registered"* ]] || false
  [ "$(key_line_count "$BRAIN_ORG/Serlinolab-Brain")" = 2 ]
}

@test "--dry-run says it would upgrade the read-only Brain key and changes nothing" {
  seed_readonly_brain_key
  local before; before=$(cat "$(BRAIN_KEYS)")
  run bash "$REPO_ROOT/provision.sh" --dry-run "$LINE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"will upgrade deploy key 'brain-mirror alice alices-mac'"* ]] || false
  [ "$(cat "$(BRAIN_KEYS)")" = "$before" ]
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team" ]
}

@test "--upgrade-brain-key upgrades by title, with nothing from the Mac, and leaves every other key alone" {
  seed_readonly_brain_key
  run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "brain-mirror alice alices-mac"
  [ "$status" -eq 0 ]
  [ "$(key_line_count "$BRAIN_ORG/Serlinolab-Brain")" = 2 ]
  grep -qF $'brain-mirror bob bobs-mac\tssh-ed25519 AAAAother brain-mirror-bobs-mac\ttrue' "$(BRAIN_KEYS)"
  awk -F'\t' '$1=="brain-mirror alice alices-mac" && $2 ~ /^ssh-ed25519 AAAAmirror/ && $3=="false"{f=1} END{exit !f}' "$(BRAIN_KEYS)"
  [ ! -e "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team" ]                  # no team repo, no team key
  run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "brain-mirror alice alices-mac"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already writable"* ]] || false
  [ "$(key_line_count "$BRAIN_ORG/Serlinolab-Brain")" = 2 ]
}

@test "--upgrade-brain-key --dry-run prints what it would do and mutates nothing" {
  seed_readonly_brain_key
  local before; before=$(cat "$(BRAIN_KEYS)")
  run bash "$REPO_ROOT/provision.sh" --dry-run --upgrade-brain-key "brain-mirror alice alices-mac"
  [ "$status" -eq 0 ]
  [[ "$output" == *"would delete deploy key"*"brain-mirror alice alices-mac"*"read_only=false"* ]] || false
  [ "$(cat "$(BRAIN_KEYS)")" = "$before" ]
}

@test "--upgrade-brain-key refuses an unknown title, a failed lookup, and a repo that is not the private Brain, changing nothing" {
  seed_readonly_brain_key
  local before; before=$(cat "$(BRAIN_KEYS)")
  run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "brain-mirror nobody nowhere"
  [ "$status" -ne 0 ]; [[ "$output" == *"no deploy key titled"* ]] || false
  FAKE_GH_FAIL_KEYS_LOOKUP=1 run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "brain-mirror alice alices-mac"
  [ "$status" -ne 0 ]; [[ "$output" == *"could not look up existing deploy keys"* ]] || false
  printf 'false\n' > "$FAKE_GH_STATE/repos/${BRAIN_ORG}__Serlinolab-Brain"
  run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "brain-mirror alice alices-mac"
  [ "$status" -ne 0 ]; [[ "$output" == *"not private"* ]] || false
  [ "$(cat "$(BRAIN_KEYS)")" = "$before" ]
}

@test "the upgrade never touches a title collision with a different key, nor a team key" {
  seed_readonly_brain_key
  local other="SERLINO-BRAIN-SETUP person=alice machine=alices-mac mirror_key=ssh-ed25519 AAAAdifferent brain-mirror-alices-mac team_key=ssh-ed25519 AAAAteam brain-team-alice"
  local before; before=$(cat "$(BRAIN_KEYS)")
  run bash "$REPO_ROOT/provision.sh" "$other"
  [ "$status" -ne 0 ]
  [[ "$output" == *"different key"* ]] || false
  [ "$(cat "$(BRAIN_KEYS)")" = "$before" ]
  # a read-only TEAM key is refused, not upgraded: the upgrade exists for the Brain key only
  rm -f "$(BRAIN_KEYS)"
  printf 'true\n' > "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team"; touch "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team.readme"
  printf 'brain-team alice alices-mac\tssh-ed25519 AAAAteam brain-team-alice\ttrue\n' > "$FAKE_GH_STATE/repos/${BRAIN_ORG}__brain-team.keys"
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected read_only=false"* ]] || false
  [ "$(key_line_count "$BRAIN_ORG/brain-team")" = 1 ]
  [ ! -s "$(BRAIN_KEYS)" ]                              # phase 1 failed: no Brain key was registered either
}

# --- MAX-1790 review: an upgrade that fails halfway must leave a way back ---------------------------------

@test "a failed re-registration after the delete is retried once, and the Mac is never left with no key" {
  seed_readonly_brain_key
  FAKE_GH_FAIL_KEY_POSTS=1 run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "brain-mirror alice alices-mac"
  [ "$status" -eq 0 ]
  [[ "$output" == *"trying once more"* ]] || false
  awk -F'\t' '$1=="brain-mirror alice alices-mac" && $2 ~ /^ssh-ed25519 AAAAmirror/ && $3=="false"{f=1} END{exit !f}' "$(BRAIN_KEYS)"
  [ "$(key_line_count "$BRAIN_ORG/Serlinolab-Brain")" = 2 ]
  [ -z "$(ls -A "$BRAIN_PROVISION_STATE" 2>/dev/null)" ]            # finished: nothing left to recover
}

@test "when both write registrations fail the read-only key is put back, and the recovery material is kept" {
  seed_readonly_brain_key
  FAKE_GH_FAIL_KEY_POSTS=2 run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "brain-mirror alice alices-mac"
  [ "$status" -ne 0 ]
  awk -F'\t' '$1=="brain-mirror alice alices-mac" && $2 ~ /^ssh-ed25519 AAAAmirror/ && $3=="true"{f=1} END{exit !f}' "$(BRAIN_KEYS)"   # back, read-only
  [[ "$output" == *"read-only key was put back"* ]] || false
  [[ "$output" == *"--upgrade-brain-key"*"brain-mirror alice alices-mac"* ]] || false
  grep -qF "ssh-ed25519 AAAAmirror" "$BRAIN_PROVISION_STATE"/*
  run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "brain-mirror alice alices-mac"   # a plain re-run finishes it
  [ "$status" -eq 0 ]
  awk -F'\t' '$1=="brain-mirror alice alices-mac" && $3=="false"{f=1} END{exit !f}' "$(BRAIN_KEYS)"
  [ "$(key_line_count "$BRAIN_ORG/Serlinolab-Brain")" = 2 ]
  [ -z "$(ls -A "$BRAIN_PROVISION_STATE" 2>/dev/null)" ]
}

@test "when every registration fails after the delete, the exact way back is printed and a re-run restores the key" {
  seed_readonly_brain_key
  FAKE_GH_FAIL_KEY_POSTS=3 run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "brain-mirror alice alices-mac"
  [ "$status" -ne 0 ]
  ! grep -q "brain-mirror alice alices-mac" "$(BRAIN_KEYS)" || false                          # the Mac has no key on GitHub now
  [[ "$output" == *"has NO key"* ]] || false
  [[ "$output" == *"ssh-ed25519 AAAAmirror"* ]] || false                                      # the public key is in the output
  [[ "$output" == *"provision.sh --upgrade-brain-key 'brain-mirror alice alices-mac'"* ]] || false
  run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "brain-mirror alice alices-mac"   # title alone is enough now
  [ "$status" -eq 0 ]
  awk -F'\t' '$1=="brain-mirror alice alices-mac" && $2 ~ /^ssh-ed25519 AAAAmirror/ && $3=="false"{f=1} END{exit !f}' "$(BRAIN_KEYS)"
  grep -qF $'brain-mirror bob bobs-mac\tssh-ed25519 AAAAother brain-mirror-bobs-mac\ttrue' "$(BRAIN_KEYS)"
}

@test "the recovery material is written BEFORE the delete: if it cannot be written, nothing is deleted" {
  seed_readonly_brain_key
  local before; before=$(cat "$(BRAIN_KEYS)")
  echo "in the way" > "$BRAIN_PROVISION_STATE"
  run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "brain-mirror alice alices-mac"
  [ "$status" -ne 0 ]
  [ "$(cat "$(BRAIN_KEYS)")" = "$before" ]
}

@test "a title that is neither on GitHub nor in the saved material is still refused" {
  seed_readonly_brain_key
  run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "brain-mirror nobody nowhere"
  [ "$status" -ne 0 ]; [[ "$output" == *"no deploy key titled"* ]] || false
}

# --- MAX-1790 round 2: an ambiguous delete, and what the saved key is allowed to do ---------------------------

T_ALICE="brain-mirror alice alices-mac"
# the file provision.sh keeps: org, repo, title, public key (tab separated), named after the title
saved_file() { printf '%s/upgrade-%s.tsv' "$BRAIN_PROVISION_STATE" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; }
write_saved() { mkdir -p "$BRAIN_PROVISION_STATE"; printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" > "$(saved_file "$T_ALICE")"; }
writable_alice() { awk -F'\t' -v t="$T_ALICE" '$1==t && $3=="false"{f=1} END{exit !f}' "$(BRAIN_KEYS)"; }

@test "K4 a delete that GitHub applied but answered with an error keeps the saved key, finds the key gone, and puts it back writable" {
  seed_readonly_brain_key
  FAKE_GH_DELETE_FAIL=after run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "$T_ALICE"
  [ "$status" -eq 0 ]
  writable_alice
  [ "$(key_line_count "$BRAIN_ORG/Serlinolab-Brain")" = 2 ]
  [ -z "$(ls -A "$BRAIN_PROVISION_STATE" 2>/dev/null)" ]            # finished: nothing left to recover
}

@test "K4 a delete that failed and left the key in place keeps the saved key and changes nothing on GitHub" {
  seed_readonly_brain_key
  local before; before=$(cat "$(BRAIN_KEYS)")
  FAKE_GH_DELETE_FAIL=before run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "$T_ALICE"
  [ "$status" -ne 0 ]
  [ "$(cat "$(BRAIN_KEYS)")" = "$before" ]
  grep -qF "ssh-ed25519 AAAAmirror" "$(saved_file "$T_ALICE")"
}

@test "K4 a delete of unknown outcome and a listing that then fails keeps the saved key; a re-run finishes the job" {
  seed_readonly_brain_key
  FAKE_GH_DELETE_FAIL=after FAKE_GH_KEYS_LOOKUP_FAIL_CALL=2 run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "$T_ALICE"
  [ "$status" -ne 0 ]
  grep -qF "ssh-ed25519 AAAAmirror" "$(saved_file "$T_ALICE")"
  run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "$T_ALICE"
  [ "$status" -eq 0 ]
  writable_alice
}

@test "S1 a stale saved key is dropped when the Mac is provisioned again with a new key, and cannot come back later" {
  printf '%s\tssh-ed25519 AAAAmirror brain-mirror-alices-mac\ttrue\n' "$T_ALICE" > "$(BRAIN_KEYS)"
  FAKE_GH_FAIL_KEY_POSTS=3 run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "$T_ALICE"
  [ "$status" -ne 0 ]
  [ -s "$(saved_file "$T_ALICE")" ]                                  # the old key is saved: the Mac has none on GitHub
  rm -f "$FAKE_GH_STATE/key_post_count"
  run bash "$REPO_ROOT/provision.sh" "${LINE/AAAAmirror/AAAAnewkey}"   # reinstalled Mac: new key, same title, via the setup line
  [ "$status" -eq 0 ]
  writable_alice
  [ ! -e "$(saved_file "$T_ALICE")" ]                                # a writable key under that title exists: nothing left to recover
  grep -v 'alices-mac' "$(BRAIN_KEYS)" > "$(BRAIN_KEYS).t" || true; mv "$(BRAIN_KEYS).t" "$(BRAIN_KEYS)"   # Max revokes this Mac
  run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "$T_ALICE"
  [ "$status" -ne 0 ]
  ! grep -q AAAAmirror "$(BRAIN_KEYS)" || false                      # the old key was not registered again
}

@test "S1 a saved key is dropped when a key under its title is found already registered" {
  printf '%s\tssh-ed25519 AAAAmirror brain-mirror-alices-mac\tfalse\n' "$T_ALICE" > "$(BRAIN_KEYS)"
  write_saved "$BRAIN_ORG" Serlinolab-Brain "$T_ALICE" "ssh-ed25519 AAAAold"
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already registered"* ]] || false
  [ ! -e "$(saved_file "$T_ALICE")" ]
}

@test "S1 --dry-run never drops a saved key" {
  printf '%s\tssh-ed25519 AAAAmirror brain-mirror-alices-mac\tfalse\n' "$T_ALICE" > "$(BRAIN_KEYS)"
  write_saved "$BRAIN_ORG" Serlinolab-Brain "$T_ALICE" "ssh-ed25519 AAAAold"
  run bash "$REPO_ROOT/provision.sh" --dry-run "$LINE"
  [ "$status" -eq 0 ]
  [ -s "$(saved_file "$T_ALICE")" ]
}

@test "S5 a saved key is used only if its organisation, repository, title and key type all match this run" {
  write_saved "$BRAIN_ORG" Serlinolab-Brain "$T_ALICE" "ssh-ed25519 AAAAold"                 # control: all four match
  run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "$T_ALICE"
  [ "$status" -eq 0 ]; writable_alice; [ ! -e "$(saved_file "$T_ALICE")" ]
  local wrong
  for wrong in "other-org|Serlinolab-Brain|$T_ALICE|ssh-ed25519 AAAAold" \
               "$BRAIN_ORG|brain-team|$T_ALICE|ssh-ed25519 AAAAold" \
               "$BRAIN_ORG|Serlinolab-Brain|brain-mirror bob bobs-mac|ssh-ed25519 AAAAold" \
               "$BRAIN_ORG|Serlinolab-Brain|$T_ALICE|ssh-rsa AAAAold"; do
    : > "$(BRAIN_KEYS)"
    IFS='|' read -r o r t k <<<"$wrong"
    write_saved "$o" "$r" "$t" "$k"
    run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "$T_ALICE"
    [ "$status" -ne 0 ]
    [ ! -s "$(BRAIN_KEYS)" ]                                                                   # nothing was registered from it
  done
}

# --- MAX-1790 final review: keys are matched by id and key material, never by title alone ---

two_alice_keys() {   # two deploy keys under one title: a different read-only key first, ours second
  printf '%s\tssh-ed25519 AAAAother brain-mirror-x\ttrue\n' "$T_ALICE" > "$(BRAIN_KEYS)"
  printf '%s\tssh-ed25519 AAAAmirror brain-mirror-alices-mac\ttrue\n' "$T_ALICE" >> "$(BRAIN_KEYS)"
}

@test "K4 --upgrade-brain-key refuses a title shared by two keys before it deletes anything" {
  two_alice_keys; local before; before=$(cat "$(BRAIN_KEYS)")
  run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "$T_ALICE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"more than one"* ]] || false
  [ "$(cat "$(BRAIN_KEYS)")" = "$before" ]
  [ ! -e "$(saved_file "$T_ALICE")" ]
}

@test "K4 a pasted line refuses a title shared by two keys and changes nothing" {
  printf '%s\tssh-ed25519 AAAAmirror brain-mirror-alices-mac\tfalse\n%s\tssh-ed25519 AAAAother brain-mirror-x\ttrue\n' "$T_ALICE" "$T_ALICE" > "$(BRAIN_KEYS)"
  local before; before=$(cat "$(BRAIN_KEYS)")   # ours is first and already writable: the old title match said "already registered"
  run bash "$REPO_ROOT/provision.sh" "$LINE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"more than one"* ]] || false
  [ "$(cat "$(BRAIN_KEYS)")" = "$before" ]
}

@test "K4 after an ambiguous delete, another key under the same title does not make the deleted key look present" {
  seed_readonly_brain_key
  FAKE_GH_DELETE_FAIL=after FAKE_GH_DELETE_ADDS_TITLE_TWIN=1 run bash "$REPO_ROOT/provision.sh" --upgrade-brain-key "$T_ALICE"
  [ "$status" -eq 0 ]
  awk -F'\t' -v t="$T_ALICE" '$1==t && $2 ~ /^ssh-ed25519 AAAAmirror/ && $3=="false"{f=1} END{exit !f}' "$(BRAIN_KEYS)"   # ours is back, writable
  [ -z "$(ls -A "$BRAIN_PROVISION_STATE" 2>/dev/null)" ]
}
