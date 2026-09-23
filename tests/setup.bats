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
  cp "$REPO_ROOT/lib/complete_setup.sh" "$work/lib/complete_setup.sh"
  # MAX-1515 review finding A: setup.sh now sources $ENGINE/lib/common.sh too, to take the
  # same lock a background sync cycle holds around its own complete_setup call.
  cp "$REPO_ROOT/lib/common.sh" "$work/lib/common.sh"
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
  #
  # repos_dir is baked into the wrapper AS A LITERAL at write time (this heredoc leaves every
  # other `$` escaped, so only repos_dir itself interpolates) - it must never be read back from
  # $BRAIN_ROOT at the wrapper's OWN run time, because MAX-1515 fix 4b tests invoke sync.sh
  # with BRAIN_ROOT overridden to $HOME/Serlino (a different path than where these bare repos
  # actually live); reading $BRAIN_ROOT dynamically there silently broke the sed rewrite and
  # leaked the raw test-scratch path back out of `remote get-url`.
  local repos_dir="$BRAIN_ROOT/repos"
  cat > "$HOME/bin/git" <<EOF
#!/bin/bash
args=("\$@")
for i in "\${!args[@]}"; do
  case "\${args[\$i]}" in
    git@brain-mirror:serlinolab/Serlinolab-Brain.git) args[\$i]="$repos_dir/mirror.git" ;;
    git@brain-team:serlinolab/brain-team.git) args[\$i]="$repos_dir/team.git" ;;
  esac
done
if [ "\${FAIL_MIRROR:-0}" = 1 ] && [[ " \$* " == *" git@brain-mirror:serlinolab/Serlinolab-Brain.git "* ]]; then exit 1; fi
if [ "\${FAIL_TEAM:-0}" = 1 ] && [[ " \$* " == *" git@brain-team:serlinolab/brain-team.git "* ]]; then exit 1; fi
if [ "\${FAIL_SPARSE:-0}" = 1 ] && [[ " \$* " == *" sparse-checkout "* ]]; then exit 1; fi
"\$REAL_GIT" "\${args[@]}" | sed -e "s#$repos_dir/mirror.git#git@brain-mirror:serlinolab/Serlinolab-Brain.git#g" -e "s#$repos_dir/team.git#git@brain-team:serlinolab/brain-team.git#g"
exit "\${PIPESTATUS[0]}"
EOF
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

@test "setup refuses an unrelated existing team repository and never reaches the launchd install" {
  # MAX-1515 fix 4a: an adoption refusal used to only set setup_ok=0 and keep running -
  # including installing and kickstarting the background job against the very folder setup
  # just refused to touch. A refusal must exit immediately, before the plist is even written.
  mkdir -p "$HOME/Serlino/.state"
  printf 'parker-v2\n' > "$HOME/Serlino/.state/layout"
  git init -q "$HOME/Serlino/team"
  git -C "$HOME/Serlino/team" remote add origin https://unrelated.example/team.git
  printf '%s\n' '#!/bin/bash' 'echo LAUNCHCTL_CALLED >> "$LAUNCHCTL_LOG"' 'exit 0' > "$HOME/bin/launchctl"
  chmod +x "$HOME/bin/launchctl"
  LAUNCHCTL_LOG="$BRAIN_ROOT/launchctl.log"; export LAUNCHCTL_LOG
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/Library/LaunchAgents/com.serlinolab.brainsync.plist" ]
  [ ! -e "$LAUNCHCTL_LOG" ]
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

@test "a failed team clone configuration leaves no team clone at all, and setup reports the failure plainly" {
  push_colleague_instructions_to_team_origin
  FAIL_SPARSE=1 BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/Serlino/team" ]
  [[ "$output" == *"pending"* ]] || false
  [ ! -e "$HOME/Serlino/.state/setup-complete" ]
  # a half-configured team/ must never leave the background job installed
  [ ! -e "$HOME/Library/LaunchAgents/com.serlinolab.brainsync.plist" ]
  # MAX-1515 review finding E: a configuration failure is not a missing-key "pending" state -
  # nothing here retries it on its own, so the message must say so plainly instead of implying
  # (as it used to) that the folders will still appear by themselves.
  [[ "$output" == *"Setup could not finish preparing the team folder. Nothing was lost. Please tell Max."* ]] || false
  [[ "$output" != *"appear on their own"* ]] || false
}

# --- MAX-1515 review remediation ---

# Finding B: $STATE/team-configured used to be trusted as proof team/ was protected - a marker
# written once and never re-checked against reality. An ordinary replacement clone (no sparse-
# checkout, no hooks) at the same path, with the marker still sitting there from before, used
# to sail through untouched forever. team_is_protected (lib/complete_setup.sh) re-derives the
# real state instead, so the next cycle must reconfigure it for real.
@test "a stale team-configured marker does not protect a replacement clone - the next cycle reconfigures it for real" {
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  local marker_before; marker_before=$(cat "$HOME/Serlino/.state/team-configured")

  push_colleague_instructions_to_team_origin
  rm -rf "$HOME/Serlino/team"
  # an ORDINARY clone - no sparse-checkout, no hooks, no core.symlinks=false - simulating a
  # replacement that never went through complete_setup at all
  "$REAL_GIT" clone -q "$BRAIN_ROOT/repos/team.git" "$HOME/Serlino/team"
  # the stale marker survives the replacement untouched, exactly as the finding describes
  [ "$(cat "$HOME/Serlino/.state/team-configured")" = "$marker_before" ]
  # proof the replacement is genuinely unprotected: an ordinary clone checked out everything,
  # including the colleague's instructions a sparse-checkout would have excluded
  [ -f "$HOME/Serlino/team/CLAUDE.md" ]

  BRAIN_ROOT="$HOME/Serlino" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]

  [ -x "$HOME/Serlino/team/.git/hooks/pre-commit" ]
  [ -x "$HOME/Serlino/team/.git/hooks/pre-push" ]
  [ "$(git -C "$HOME/Serlino/team" config core.hooksPath)" = "$HOME/Serlino/team/.git/hooks" ]
  [ "$(git -C "$HOME/Serlino/team" config core.symlinks)" = false ]
  # the sparse-checkout reapply that reconfiguration performs removes what should never have
  # been checked out in the first place
  [ ! -e "$HOME/Serlino/team/CLAUDE.md" ]
}

# Finding C: sync.sh used to discard a configuration failure (`complete_setup || true`) and let
# commit_local/sync_team run anyway against whatever was left on disk. Reproduces the case that
# actually matters: team/ already exists at the expected origin (adopted, not freshly cloned by
# this run) but was never actually configured - complete_setup's own cleanup only removes what
# ITS OWN clone created, so this half-adopted state survives a failed reconfiguration attempt,
# and the cycle must skip it rather than fetch/rebase a colleague's push straight onto disk.
@test "a discarded configuration failure never lets sync.sh commit or rebase into an unprotected team/" {
  # an ordinary, unconfigured clone of the (still colleague-instruction-free) team origin -
  # simulates one that never went through complete_setup, adopted on the next cycle below
  "$REAL_GIT" clone -q "$BRAIN_ROOT/repos/team.git" "$HOME/Serlino/team"
  local before; before=$(git -C "$HOME/Serlino/team" rev-parse HEAD)

  push_colleague_instructions_to_team_origin

  FAIL_SPARSE=1 BRAIN_ROOT="$HOME/Serlino" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]

  # never deleted - this run adopted it rather than cloning it itself
  [ -d "$HOME/Serlino/team/.git" ]
  # never fetched/rebased - the colleague's push never reached the local working tree
  [ "$(git -C "$HOME/Serlino/team" rev-parse HEAD)" = "$before" ]
  [ ! -e "$HOME/Serlino/team/CLAUDE.md" ]
  [ ! -e "$HOME/Serlino/team/.claude" ]
  grep -q "skipping this cycle" "$HOME/Serlino/.state/sync.log"
}

# Finding A: setup.sh and a background sync cycle both call complete_setup. Before this fix,
# only sync.sh took the lock - the two could run complete_setup at the same moment, and the
# loser's failed-clone cleanup (an unconditional rm -rf) could delete whichever side actually
# finished. setup.sh now takes the same lock, so the two can never be inside complete_setup
# together in the first place.
@test "setup.sh never runs complete_setup while a background cycle holds the lock" {
  # Pre-seed the layout/person state a first setup.sh run would have written, so this test's
  # OWN concurrent processes race only on the lock - not on setup.sh's unrelated AC-8 "not
  # made by this setup" guard, which would otherwise fire the instant the background cycle's
  # own `mkdir -p $STATE` (lib/common.sh) creates $ROOT first.
  mkdir -p "$HOME/Serlino/.state"
  printf 'parker-v2\n' > "$HOME/Serlino/.state/layout"
  printf 'alice\n' > "$HOME/Serlino/.state/person"

  # A short hold: long enough that setup.sh's own first attempt below reliably lands inside
  # it (acquire_lock is the very first thing either side does), short enough that its retry
  # (a fixed 2s wait) reliably lands after it - the spec allows setup.sh to either finish this
  # run or report still-busy, so keeping the hold well under that 2s margin is what makes the
  # collision itself deterministic rather than the specific outcome this run reports.
  BRAIN_ROOT="$HOME/Serlino" SYNC_HOLD_SECONDS=0.5 bash "$REPO_ROOT/sync.sh" &
  local holder=$!
  sleep 0.15   # let the background cycle actually acquire the lock first
  [ -d "$HOME/Serlino/.state/run.lock" ]

  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  wait "$holder"

  # the collision was detected and never raced into complete_setup together - whichever side
  # actually finished configuring it, team/ ends up pointed at the real origin, never a
  # corrupted half-clone from two attempts stepping on each other
  [[ "$output" == *"already being completed in the background"* ]] || false
  [ -d "$HOME/Serlino/team/.git" ]
  [ "$(git -C "$HOME/Serlino/team" remote get-url origin)" = 'git@brain-team:serlinolab/brain-team.git' ]
}

# Finding A: a concurrent winner's clone must survive a losing attempt's own failed-clone
# cleanup. Reproduced deterministically (real concurrency races on timing) by making the ONE
# `git clone` call this attempt makes stand in for "another process finished first": the
# wrapper performs a real clone as a side effect, exactly what a concurrent winner would have
# left behind, then reports failure for THIS call, exactly what the loser of a real race sees.
@test "a losing clone attempt's own cleanup never deletes a clone that is genuinely there now" {
  # Simulates the race deterministically instead of depending on real timing: this attempt's
  # OWN `git clone` call performs a real clone (through the same alias-rewriting wrapper every
  # other command in this fixture uses - exactly what a concurrent winner would have left
  # behind) and then reports failure for the CALLER, exactly what the loser of a real race
  # sees when it tries to clone into a destination another process just finished.
  local fakebin; fakebin="$(mktemp -d)"
  cat > "$fakebin/git" <<EOF
#!/bin/bash
if [ "\$1" = clone ]; then
  "$HOME/bin/git" "\$@"
  exit 1
fi
exec "$HOME/bin/git" "\$@"
EOF
  chmod +x "$fakebin/git"

  mkdir -p "$HOME/Serlino/.state"
  printf 'parker-v2\n' > "$HOME/Serlino/.state/layout"
  printf 'testperson\n' > "$HOME/Serlino/.state/person"
  PATH="$fakebin:$HOME/bin:$PATH" BRAIN_ROOT="$HOME/Serlino" run bash "$REPO_ROOT/sync.sh"

  [ "$status" -eq 0 ]
  [ -d "$HOME/Serlino/team/.git" ]
  [ "$(cd "$HOME/Serlino/team" && git remote get-url origin)" = 'git@brain-team:serlinolab/brain-team.git' ]
  [[ "$output" == *"already completed elsewhere"* ]] || false
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

# --- MAX-1515 change A: setup finishes itself in the background, no second Terminal paste ---

# (a)
@test "first run with keys refused: reports pending, the plist is still written, setup-started is recorded, nothing is cloned" {
  FAIL_TEAM=1 FAIL_MIRROR=1 BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *pending* ]] || false
  [ -f "$HOME/Library/LaunchAgents/com.serlinolab.brainsync.plist" ]
  [ -f "$HOME/Serlino/.state/setup-started" ]
  [ ! -e "$HOME/Serlino/team" ]
  [ ! -e "$HOME/Serlino/serlinolab" ]
}

# (b)
@test "a later sync cycle completes setup once the keys are simulated as registered, with no user action" {
  FAIL_TEAM=1 BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/Serlino/team" ]
  [ ! -e "$HOME/Serlino/serlinolab" ]

  push_colleague_instructions_to_team_origin

  # the key is now "registered" - the fake git wrapper no longer fails the team clone
  BRAIN_ROOT="$HOME/Serlino" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  [ -d "$HOME/Serlino/team/.git" ]
  [ -d "$HOME/Serlino/serlinolab/.git" ]
  [ -x "$HOME/Serlino/team/.git/hooks/pre-commit" ]
  [ -x "$HOME/Serlino/team/.git/hooks/pre-push" ]
  [ "$(git -C "$HOME/Serlino/team" config core.hooksPath)" = "$HOME/Serlino/team/.git/hooks" ]
  [ "$(git -C "$HOME/Serlino/team" config core.symlinks)" = false ]
  [ -f "$HOME/Serlino/.state/team-configured" ]
  [ -f "$HOME/Serlino/.state/setup-complete" ]
  [ ! -e "$HOME/Serlino/team/CLAUDE.md" ]
  [ ! -e "$HOME/Serlino/team/.claude" ]
}

# (c)
@test "a completed setup is left untouched by later cycles - no reclone, no config or hook drift" {
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  local before_config before_precommit before_prepush before_team_inode before_mirror_inode
  before_config=$(git -C "$HOME/Serlino/team" config --list)
  before_precommit=$(shasum "$HOME/Serlino/team/.git/hooks/pre-commit")
  before_prepush=$(shasum "$HOME/Serlino/team/.git/hooks/pre-push")
  before_team_inode=$(stat -f %i "$HOME/Serlino/team/.git")
  before_mirror_inode=$(stat -f %i "$HOME/Serlino/serlinolab/.git")

  BRAIN_ROOT="$HOME/Serlino" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  BRAIN_ROOT="$HOME/Serlino" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]

  [ "$(git -C "$HOME/Serlino/team" config --list)" = "$before_config" ]
  [ "$(shasum "$HOME/Serlino/team/.git/hooks/pre-commit")" = "$before_precommit" ]
  [ "$(shasum "$HOME/Serlino/team/.git/hooks/pre-push")" = "$before_prepush" ]
  # an inode unchanged across two cycles proves complete_setup never re-cloned - a clone would
  # recreate .git under a fresh inode
  [ "$(stat -f %i "$HOME/Serlino/team/.git")" = "$before_team_inode" ]
  [ "$(stat -f %i "$HOME/Serlino/serlinolab/.git")" = "$before_mirror_inode" ]
}

# (d)
@test "still pending past SETUP_PENDING_ALERT_HOURS raises the attention file in plain words, cleared once complete" {
  FAIL_TEAM=1 BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]

  SETUP_PENDING_ALERT_HOURS=0 FAIL_TEAM=1 BRAIN_ROOT="$HOME/Serlino" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  [ -f "$HOME/Serlino/SOMETHING NEEDS YOUR ATTENTION.txt" ]
  grep -qi "not ready yet" "$HOME/Serlino/SOMETHING NEEDS YOUR ATTENTION.txt"
  run grep -inE '\b(git|repo|repository|commit|push|pull|branch|clone|merge|PR|key|SSH)\b' "$HOME/Serlino/SOMETHING NEEDS YOUR ATTENTION.txt"
  [ "$status" -ne 0 ]

  BRAIN_ROOT="$HOME/Serlino" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/Serlino/SOMETHING NEEDS YOUR ATTENTION.txt" ]
}

# (e)
@test "personal/ is never touched by a pending or a completing background setup cycle" {
  FAIL_TEAM=1 BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  mkdir -p "$HOME/Serlino/personal/ideas"
  echo "my plan" > "$HOME/Serlino/personal/ideas/plan.txt"
  local before_mtime
  before_mtime=$(stat -f %m "$HOME/Serlino/personal/ideas/plan.txt")

  FAIL_TEAM=1 BRAIN_ROOT="$HOME/Serlino" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  BRAIN_ROOT="$HOME/Serlino" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]

  [ "$(cat "$HOME/Serlino/personal/ideas/plan.txt")" = "my plan" ]
  [ "$(stat -f %m "$HOME/Serlino/personal/ideas/plan.txt")" = "$before_mtime" ]
  [ ! -d "$HOME/Serlino/personal/.git" ]
  [ ! -d "$HOME/Serlino/personal/ideas/.git" ]
}

# (f)
@test "a background cycle facing a foreign team origin never adopts it, and raises the attention marker" {
  FAIL_TEAM=1 BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/Serlino/team" ]
  git init -q "$HOME/Serlino/team"
  git -C "$HOME/Serlino/team" remote add origin https://unrelated.example/team.git

  BRAIN_ROOT="$HOME/Serlino" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -ne 0 ]
  [ "$(git -C "$HOME/Serlino/team" remote get-url origin)" = "https://unrelated.example/team.git" ]
  [ ! -f "$HOME/Serlino/.state/team-configured" ]
  [ -f "$HOME/Serlino/SOMETHING NEEDS YOUR ATTENTION.txt" ]
  grep -qi "not connected to where it should be" "$HOME/Serlino/SOMETHING NEEDS YOUR ATTENTION.txt"
}
