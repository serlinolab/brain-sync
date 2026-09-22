#!/usr/bin/env bats
load 'helpers'

setup_setup_test() {
  BRAIN_ROOT="$(mktemp -d)"; export BRAIN_ROOT
  HOME="$(mktemp -d)"; export HOME
  mkdir -p "$HOME/bin" "$BRAIN_ROOT/repos"
  REAL_GIT="$(type -P git)"; export REAL_GIT
  git init -q --bare "$BRAIN_ROOT/repos/engine.git"
  git init -q --bare "$BRAIN_ROOT/repos/mirror.git"
  git init -q --bare "$BRAIN_ROOT/repos/team.git"
  local work; work="$(mktemp -d)"
  git init -q -b main "$work"
  mkdir -p "$work/lib" "$work/templates"
  cp "$REPO_ROOT/lib/launcher.sh" "$work/lib/launcher.sh"
  cp "$REPO_ROOT/lib/secretscan.sh" "$work/lib/secretscan.sh"
  cp "$REPO_ROOT/lib/team_layout.sh" "$work/lib/team_layout.sh"
  cp -r "$REPO_ROOT/templates/." "$work/templates/"
  git -C "$work" add -A; git -C "$work" -c user.name=fixture -c user.email=fixture@example.com commit -qm engine
  git -C "$work" remote add origin "$BRAIN_ROOT/repos/engine.git"; git -C "$work" push -q origin main
  rm -rf "$work"
  # the team repo needs an initial commit (origin/main) - provision.sh does this in reality
  local teamwork; teamwork="$(mktemp -d)"
  git init -q -b main "$teamwork"
  cp "$REPO_ROOT/templates/team-repo-README.md" "$teamwork/README.md"
  git -C "$teamwork" add -A; git -C "$teamwork" -c user.name=fixture -c user.email=fixture@example.com commit -qm init
  git -C "$teamwork" remote add origin "$BRAIN_ROOT/repos/team.git"; git -C "$teamwork" push -q origin main
  rm -rf "$teamwork"
  # Rewrites the ssh:// alias URLs to local bare-repo paths going IN (so clone/fetch/push
  # work without real SSH), and rewrites them back to the alias going OUT of `remote
  # get-url` (so a real git's stored/reported origin looks the same as it would on a real
  # Mac, where the alias is literal and only resolves to a path at connect time). Without
  # the return trip, a freshly cloned repo's origin would read back as the test's bare path
  # and every later remote_matches() re-check would see a false mismatch.
  printf '%s\n' '#!/bin/bash' \
    'args=("$@")' \
    'for i in "${!args[@]}"; do' \
    '  case "${args[$i]}" in' \
    '    git@brain-mirror:serlinolab/Serlinolab-Brain.git) args[$i]="$BRAIN_ROOT/repos/mirror.git" ;;' \
    '    git@brain-team:serlinolab/brain-team.git) args[$i]="$BRAIN_ROOT/repos/team.git" ;;' \
    '  esac' \
    'done' \
    'if [ "${FAIL_MIRROR:-0}" = 1 ] && [[ " $* " == *" git@brain-mirror:serlinolab/Serlinolab-Brain.git "* ]]; then exit 1; fi' \
    '"$REAL_GIT" "${args[@]}" | sed -e "s#$BRAIN_ROOT/repos/mirror.git#git@brain-mirror:serlinolab/Serlinolab-Brain.git#g" -e "s#$BRAIN_ROOT/repos/team.git#git@brain-team:serlinolab/brain-team.git#g"' \
    'exit "${PIPESTATUS[0]}"' > "$HOME/bin/git"
  printf '%s\n' '#!/bin/bash' 'exit 0' > "$HOME/bin/launchctl"
  chmod +x "$HOME/bin/git" "$HOME/bin/launchctl"
  export PATH="$HOME/bin:$PATH"
  export BRAIN_SYNC_REMOTE="$BRAIN_ROOT/repos/engine.git"
}

setup() { setup_setup_test; }
teardown() {
  case "${BRAIN_ROOT:-}" in /tmp/*|/private/tmp/*|/var/folders/*) rm -rf "$BRAIN_ROOT" ;; esac
  case "${HOME:-}" in /tmp/*|/private/tmp/*|/var/folders/*) rm -rf "$HOME" ;; esac
}

@test "setup refuses an unrelated existing team repository" {
  # Must build a valid parker-v1 layout first, or setup's earlier AC-8 "not made by this
  # setup" guard fires and this test never reaches the remote-mismatch refusal it means to
  # exercise - it used to pass for the wrong reason (a bats-on-macOS-bash-3.2 gotcha:
  # intermediate `[[ ]]` failures inside a @test do not fail the test, only `[ ]`/external
  # commands do - see the note on the final `run git -C ... remote get-url` assertion below).
  mkdir -p "$HOME/Serlino/.state"
  printf 'parker-v1\n' > "$HOME/Serlino/.state/layout"
  git init -q "$HOME/Serlino/team"
  git -C "$HOME/Serlino/team" remote add origin https://unrelated.example/team.git
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  # grep, not `[[ ]]`: on macOS's bash 3.2, an intermediate `[[ ]]` failure inside a bats
  # @test does NOT fail the test (only `[ ]`/external commands do - a real gotcha this test
  # tripped on before this fix). grep -qF is an external command and fails the test properly.
  printf '%s' "$output" | grep -qF "$HOME/Serlino/team"
  printf '%s' "$output" | grep -qF "unrelated.example/team.git"
  [ ! -e "$HOME/Serlino/team/serlinolab" ]
}

@test "setup refuses an unrelated mirror nested inside an otherwise valid team clone" {
  mkdir -p "$HOME/Serlino/.state"
  printf 'parker-v1\n' > "$HOME/Serlino/.state/layout"
  git init -q "$HOME/Serlino/team"
  "$REAL_GIT" -C "$HOME/Serlino/team" remote add origin 'git@brain-team:serlinolab/brain-team.git'
  git init -q "$HOME/Serlino/team/serlinolab"
  git -C "$HOME/Serlino/team/serlinolab" remote add origin https://unrelated.example/mirror.git
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HOME/Serlino/team/serlinolab"*"unrelated.example/mirror.git"* ]] || false
}

@test "setup records person once and refuses a later different person" {
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  BRAIN_PERSON=bob run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/Serlino/.state/person")" = alice ]
  [[ "$output" == *"found 'alice', requested 'bob'"* ]] || false
}

@test "person mismatch stops before cloning a missing team checkout" {
  mkdir -p "$HOME/Serlino/.state"
  printf 'parker-v1\n' > "$HOME/Serlino/.state/layout"
  printf '%s\n' alice > "$HOME/Serlino/.state/person"
  BRAIN_PERSON=bob run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/Serlino/team" ]
  [[ "$output" == *"found 'alice', requested 'bob'"* ]] || false
}

@test "setup refuses a correct fetch URL with a foreign push URL" {
  mkdir -p "$HOME/Serlino/.state"
  printf 'parker-v1\n' > "$HOME/Serlino/.state/layout"
  git init -q "$HOME/Serlino/team"
  "$REAL_GIT" -C "$HOME/Serlino/team" remote add origin 'git@brain-team:serlinolab/brain-team.git'
  git -C "$HOME/Serlino/team" remote set-url --add --push origin ssh://attacker.invalid/leak.git
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"including push URLs"* ]] || false
}

@test "setup does not adopt team/serlinolab through team's own repository" {
  # remote_matches requires a .git AT the exact path, not one discovered by walking up to an
  # ancestor - otherwise `git -C team/serlinolab remote get-url origin` would silently answer
  # with team's own (correct) remote for a directory that isn't a clone of the mirror at all.
  mkdir -p "$HOME/Serlino/.state"
  printf 'parker-v1\n' > "$HOME/Serlino/.state/layout"
  git init -q "$HOME/Serlino/team"
  "$REAL_GIT" -C "$HOME/Serlino/team" remote add origin 'git@brain-team:serlinolab/brain-team.git'
  mkdir -p "$HOME/Serlino/team/serlinolab"
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HOME/Serlino/team/serlinolab"*"including push URLs"* ]] || false
}

@test "malformed private keys do not leave an empty public key" {
  mkdir -p "$HOME/.ssh"
  printf 'not a key\n' > "$HOME/.ssh/brain_mirror_ed25519"
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/.ssh/brain_mirror_ed25519.pub" ]
}

@test "failed setup never writes the completion marker" {
  FAIL_MIRROR=1 BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/Serlino/.state/setup-complete" ]
}

@test "a successful setup lays out team/serlinolab nested, personal folders, and the signpost" {
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [ -d "$HOME/Serlino/team/.git" ]
  [ -d "$HOME/Serlino/team/serlinolab/.git" ]
  [ -d "$HOME/Serlino/personal/brands" ]
  [ -d "$HOME/Serlino/personal/ideas" ]
  [ -d "$HOME/Serlino/personal/finds" ]
  [ -f "$HOME/Serlino/personal/README.md" ]
  [ -f "$HOME/Serlino/CLAUDE.md" ]
  [ -L "$HOME/Serlino/AGENTS.md" ]
  [ "$(readlink "$HOME/Serlino/AGENTS.md")" = CLAUDE.md ]
  [ "$(cat "$HOME/Serlino/.state/layout")" = parker-v1 ]
  [ -x "$HOME/Serlino/team/.git/hooks/pre-commit" ]
  [ -x "$HOME/Serlino/team/.git/hooks/pre-push" ]
  [[ "$output" == *"SERLINO-BRAIN-SETUP person=alice machine="*"mirror_key=ssh-ed25519"*"team_key=ssh-ed25519"* ]] || false
}

@test "setup never overwrites an existing personal README" {
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  printf 'my own words\n' > "$HOME/Serlino/personal/README.md"
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/Serlino/personal/README.md")" = 'my own words' ]
}

# AC-8
@test "setup refuses to touch a pre-existing folder it did not create (the MAX-1514 layout)" {
  mkdir -p "$HOME/Serlino/.state"
  date -u +%FT%TZ > "$HOME/Serlino/.state/setup-complete"   # old layout: has this, never had .state/layout
  mkdir -p "$HOME/Serlino/personal/shared" "$HOME/Serlino/serlinolab"
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"was not made by this setup"* ]] || false
  [ ! -d "$HOME/Serlino/team" ]
  [ ! -f "$HOME/Serlino/CLAUDE.md" ]
}

@test "setup refuses a hand-made ~/Serlino folder" {
  mkdir -p "$HOME/Serlino/whatever"
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"was not made by this setup"* ]] || false
  [ ! -d "$HOME/Serlino/.state" ]
}

@test "re-running setup on its own parker-v1 layout still works" {
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
}
