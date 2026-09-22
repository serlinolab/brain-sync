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
    'if [ "${FAIL_SPARSE:-0}" = 1 ] && [[ " $* " == *" sparse-checkout "* ]]; then exit 1; fi' \
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
  # Must build a valid parker-v2 layout first, or setup's earlier AC-8 "not made by this
  # setup" guard fires and this test never reaches the remote-mismatch refusal it means to
  # exercise - it used to pass for the wrong reason (a bats-on-macOS-bash-3.2 gotcha:
  # intermediate `[[ ]]` failures inside a @test do not fail the test, only `[ ]`/external
  # commands do - see the note on the final `run git -C ... remote get-url` assertion below).
  mkdir -p "$HOME/Serlino/.state"
  printf 'parker-v2\n' > "$HOME/Serlino/.state/layout"
  git init -q "$HOME/Serlino/team"
  git -C "$HOME/Serlino/team" remote add origin https://unrelated.example/team.git
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  # grep, not `[[ ]]`: on macOS's bash 3.2, an intermediate `[[ ]]` failure inside a bats
  # @test does NOT fail the test (only `[ ]`/external commands do - a real gotcha this test
  # tripped on before this fix). grep -qF is an external command and fails the test properly.
  printf '%s' "$output" | grep -qF "$HOME/Serlino/team"
  printf '%s' "$output" | grep -qF "unrelated.example/team.git"
  [ ! -e "$HOME/Serlino/serlinolab" ]
}

@test "setup refuses an unrelated mirror beside an otherwise valid team clone" {
  mkdir -p "$HOME/Serlino/.state"
  printf 'parker-v2\n' > "$HOME/Serlino/.state/layout"
  git init -q "$HOME/Serlino/team"
  "$REAL_GIT" -C "$HOME/Serlino/team" remote add origin 'git@brain-team:serlinolab/brain-team.git'
  git init -q "$HOME/Serlino/serlinolab"
  git -C "$HOME/Serlino/serlinolab" remote add origin https://unrelated.example/mirror.git
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HOME/Serlino/serlinolab"*"unrelated.example/mirror.git"* ]] || false
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
  printf 'parker-v2\n' > "$HOME/Serlino/.state/layout"
  printf '%s\n' alice > "$HOME/Serlino/.state/person"
  BRAIN_PERSON=bob run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/Serlino/team" ]
  [[ "$output" == *"found 'alice', requested 'bob'"* ]] || false
}

@test "setup refuses a correct fetch URL with a foreign push URL" {
  mkdir -p "$HOME/Serlino/.state"
  printf 'parker-v2\n' > "$HOME/Serlino/.state/layout"
  git init -q "$HOME/Serlino/team"
  "$REAL_GIT" -C "$HOME/Serlino/team" remote add origin 'git@brain-team:serlinolab/brain-team.git'
  git -C "$HOME/Serlino/team" remote set-url --add --push origin ssh://attacker.invalid/leak.git
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"including push URLs"* ]] || false
}

# AC-8 (amended): the earlier parker-v1 nested layout (team/serlinolab) is refused exactly
# like any other stranger folder - nobody has installed it, so there is no migration path,
# only refusal.
@test "setup refuses a ~/Serlino whose marker is the earlier parker-v1 layout" {
  mkdir -p "$HOME/Serlino/.state" "$HOME/Serlino/team/serlinolab"
  printf 'parker-v1\n' > "$HOME/Serlino/.state/layout"
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"was not made by this setup"* ]] || false
  [ ! -e "$HOME/Serlino/serlinolab" ]
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

@test "a successful setup lays out serlinolab beside team, personal folders, and the signpost" {
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [ -d "$HOME/Serlino/team/.git" ]
  [ -d "$HOME/Serlino/serlinolab/.git" ]
  [ -d "$HOME/Serlino/personal/brands" ]
  [ -d "$HOME/Serlino/personal/ideas" ]
  [ -d "$HOME/Serlino/personal/finds" ]
  [ -f "$HOME/Serlino/personal/README.md" ]
  [ -f "$HOME/Serlino/CLAUDE.md" ]
  [ -L "$HOME/Serlino/AGENTS.md" ]
  [ "$(readlink "$HOME/Serlino/AGENTS.md")" = CLAUDE.md ]
  [ "$(cat "$HOME/Serlino/.state/layout")" = parker-v2 ]
  [ -x "$HOME/Serlino/team/.git/hooks/pre-commit" ]
  [ -x "$HOME/Serlino/team/.git/hooks/pre-push" ]
  [[ "$output" == *"SERLINO-BRAIN-SETUP person=alice machine="*"mirror_key=ssh-ed25519"*"team_key=ssh-ed25519"* ]] || false
}

# Review fix 1: a creator's global git config can set a relative core.hooksPath (e.g.
# .githooks). Unpinned, that makes git skip our installed .git/hooks entirely and run
# whatever a colleague committed into team/.githooks/ instead - here, a hook that writes a
# marker file. The repo-local hooksPath setup.sh installs must always win over the global one.
@test "a permissive global core.hooksPath cannot make git skip our installed team hooks" {
  local teamwork; teamwork="$(mktemp -d)"
  "$REAL_GIT" clone -q "$BRAIN_ROOT/repos/team.git" "$teamwork"
  mkdir -p "$teamwork/.githooks"
  printf '#!/bin/bash\necho ran > "%s/hook_marker"\nexit 0\n' "$BRAIN_ROOT" > "$teamwork/.githooks/pre-commit"
  chmod +x "$teamwork/.githooks/pre-commit"
  git -C "$teamwork" add -A
  git -C "$teamwork" -c user.name=fixture -c user.email=fixture@example.com commit -qm "colleague adds .githooks"
  git -C "$teamwork" push -q origin main
  rm -rf "$teamwork"

  local global_conf="$BRAIN_ROOT/global-gitconfig"
  printf '[core]\n  hooksPath = .githooks\n' > "$global_conf"

  GIT_CONFIG_GLOBAL="$global_conf" BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]

  echo "a note" >> "$HOME/Serlino/team/note.txt"
  GIT_CONFIG_GLOBAL="$global_conf" BRAIN_ROOT="$HOME/Serlino" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$BRAIN_ROOT/hook_marker" ]

  printf 'ghp_%s\n' "$(printf 'a%.0s' $(seq 1 36))" > "$HOME/Serlino/team/secret.txt"
  GIT_CONFIG_GLOBAL="$global_conf" BRAIN_ROOT="$HOME/Serlino" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  grep -q "REJECT secret: secret.txt" "$HOME/Serlino/.state/sync.log"
}

# Review fix 2: a colleague can commit symlinks that point outside team/ (a credential
# directory, the read-only mirror, the signpost). Left as real symlinks, writing through them
# escapes team/. core.symlinks=false on the team clone makes git materialize them as small
# plain files holding the target text instead.
@test "a colleague's symlinks materialize as plain files, never real symlinks" {
  local teamwork; teamwork="$(mktemp -d)"
  "$REAL_GIT" clone -q "$BRAIN_ROOT/repos/team.git" "$teamwork"
  ln -s ../../.ssh "$teamwork/keys"
  ln -s ../serlinolab "$teamwork/brain"
  ln -s ../CLAUDE.md "$teamwork/note"
  git -C "$teamwork" add -A
  git -C "$teamwork" -c user.name=fixture -c user.email=fixture@example.com commit -qm "colleague adds symlinks"
  git -C "$teamwork" push -q origin main
  rm -rf "$teamwork"

  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]

  echo "a note" >> "$HOME/Serlino/team/note2.txt"
  BRAIN_ROOT="$HOME/Serlino" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]

  run find "$HOME/Serlino/team" -type l
  [ -z "$output" ]
  [ -f "$HOME/Serlino/team/keys" ]
  [ "$(cat "$HOME/Serlino/team/keys")" = "../../.ssh" ]
  [ -f "$HOME/Serlino/team/note" ]
  [ "$(cat "$HOME/Serlino/team/note")" = "../CLAUDE.md" ]
}

# Review fix 3: a normal `git clone` checks out HEAD before sparse-checkout is configured, so
# a pre-existing committed CLAUDE.md/.claude briefly lands on disk. Push that content to the
# team origin before the first setup - a --no-checkout clone, configured, then explicitly
# checked out, never materializes it at all.
push_colleague_instructions_to_team_origin() {
  local teamwork; teamwork="$(mktemp -d)"
  "$REAL_GIT" clone -q "$BRAIN_ROOT/repos/team.git" "$teamwork"
  echo "colleague instructions" > "$teamwork/CLAUDE.md"
  mkdir -p "$teamwork/.claude/rules"
  echo "a rule" > "$teamwork/.claude/rules/x.md"
  git -C "$teamwork" add -A
  git -C "$teamwork" -c user.name=fixture -c user.email=fixture@example.com commit -qm "colleague adds instructions"
  git -C "$teamwork" push -q origin main
  rm -rf "$teamwork"
}

@test "a colleague's pre-existing CLAUDE.md and .claude never land on disk, even right after the first setup" {
  push_colleague_instructions_to_team_origin
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/Serlino/team/CLAUDE.md" ]
  [ ! -e "$HOME/Serlino/team/.claude" ]
}

@test "a failed team clone configuration leaves no team clone at all, and setup reports pending" {
  push_colleague_instructions_to_team_origin
  FAIL_SPARSE=1 BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/Serlino/team" ]
  [[ "$output" == *"pending"* ]] || false
  [ ! -e "$HOME/Serlino/.state/setup-complete" ]
  # a half-configured team/ must never leave the background job installed
  [ ! -e "$HOME/Library/LaunchAgents/com.serlinolab.brainsync.plist" ]
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

@test "re-running setup on its own parker-v2 layout still works" {
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
}
