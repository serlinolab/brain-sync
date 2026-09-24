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
  # with BRAIN_ROOT overridden to $HOME/Serlinolab (a different path than where these bare repos
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
# MAX-1515 re-review, finding F1: narrower than FAIL_SPARSE above - FAIL_SPARSE fails
# sparse-checkout init too, so the pattern file never even gets written. This fails ONLY
# sparse-checkout reapply, reproducing the finding's exact gap: init and the pattern-file
# write both succeed, only the step that actually applies the pattern to the working tree fails.
# (plain text, no backticks - this whole block is INSIDE an unquoted heredoc, where a backtick
# pair is a command substitution run right now, not a quoting mark - see below)
if [ "\${FAIL_SPARSE_REAPPLY:-0}" = 1 ] && [[ " \$* " == *" sparse-checkout "* ]] && [[ " \$* " == *" reapply "* ]]; then exit 1; fi
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
  mkdir -p "$HOME/Serlinolab/.state"
  printf 'parker-v2\n' > "$HOME/Serlinolab/.state/layout"
  git init -q "$HOME/Serlinolab/team"
  git -C "$HOME/Serlinolab/team" remote add origin https://unrelated.example/team.git
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  # grep, not `[[ ]]`: on macOS's bash 3.2, an intermediate `[[ ]]` failure inside a bats
  # @test does NOT fail the test (only `[ ]`/external commands do - a real gotcha this test
  # tripped on before this fix). grep -qF is an external command and fails the test properly.
  printf '%s' "$output" | grep -qF "$HOME/Serlinolab/team"
  printf '%s' "$output" | grep -qF "unrelated.example/team.git"
  [ ! -e "$HOME/Serlinolab/Serlinolab_Brain" ]
}

@test "setup refuses an unrelated existing team repository and never reaches the launchd install" {
  # MAX-1515 fix 4a: an adoption refusal used to only set setup_ok=0 and keep running -
  # including installing and kickstarting the background job against the very folder setup
  # just refused to touch. A refusal must exit immediately, before the plist is even written.
  mkdir -p "$HOME/Serlinolab/.state"
  printf 'parker-v2\n' > "$HOME/Serlinolab/.state/layout"
  git init -q "$HOME/Serlinolab/team"
  git -C "$HOME/Serlinolab/team" remote add origin https://unrelated.example/team.git
  printf '%s\n' '#!/bin/bash' 'echo LAUNCHCTL_CALLED >> "$LAUNCHCTL_LOG"' 'exit 0' > "$HOME/bin/launchctl"
  chmod +x "$HOME/bin/launchctl"
  LAUNCHCTL_LOG="$BRAIN_ROOT/launchctl.log"; export LAUNCHCTL_LOG
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/Library/LaunchAgents/com.serlinolab.brainsync.plist" ]
  [ ! -e "$LAUNCHCTL_LOG" ]
}

@test "setup refuses an unrelated mirror beside an otherwise valid team clone" {
  mkdir -p "$HOME/Serlinolab/.state"
  printf 'parker-v2\n' > "$HOME/Serlinolab/.state/layout"
  git init -q "$HOME/Serlinolab/team"
  "$REAL_GIT" -C "$HOME/Serlinolab/team" remote add origin 'git@brain-team:serlinolab/brain-team.git'
  git init -q "$HOME/Serlinolab/Serlinolab_Brain"
  git -C "$HOME/Serlinolab/Serlinolab_Brain" remote add origin https://unrelated.example/mirror.git
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HOME/Serlinolab/Serlinolab_Brain"*"unrelated.example/mirror.git"* ]] || false
}

@test "setup records person once and refuses a later different person" {
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  BRAIN_PERSON=bob run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/Serlinolab/.state/person")" = alice ]
  [[ "$output" == *"found 'alice', requested 'bob'"* ]] || false
}

@test "person mismatch stops before cloning a missing team checkout" {
  mkdir -p "$HOME/Serlinolab/.state"
  printf 'parker-v2\n' > "$HOME/Serlinolab/.state/layout"
  printf '%s\n' alice > "$HOME/Serlinolab/.state/person"
  BRAIN_PERSON=bob run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/Serlinolab/team" ]
  [[ "$output" == *"found 'alice', requested 'bob'"* ]] || false
}

@test "setup refuses a correct fetch URL with a foreign push URL" {
  mkdir -p "$HOME/Serlinolab/.state"
  printf 'parker-v2\n' > "$HOME/Serlinolab/.state/layout"
  git init -q "$HOME/Serlinolab/team"
  "$REAL_GIT" -C "$HOME/Serlinolab/team" remote add origin 'git@brain-team:serlinolab/brain-team.git'
  git -C "$HOME/Serlinolab/team" remote set-url --add --push origin ssh://attacker.invalid/leak.git
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"including push URLs"* ]] || false
}

# AC-8 (amended): the earlier parker-v1 nested layout (team/serlinolab) is refused exactly
# like any other stranger folder - nobody has installed it, so there is no migration path,
# only refusal.
@test "setup refuses a ~/Serlinolab whose marker is the earlier parker-v1 layout" {
  mkdir -p "$HOME/Serlinolab/.state" "$HOME/Serlinolab/team/serlinolab"
  printf 'parker-v1\n' > "$HOME/Serlinolab/.state/layout"
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"was not made by this setup"* ]] || false
  [ ! -e "$HOME/Serlinolab/Serlinolab_Brain" ]
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
  [ ! -e "$HOME/Serlinolab/.state/setup-complete" ]
}

@test "a successful setup lays out Serlinolab_Brain beside team, personal folders, and the signpost" {
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [ -d "$HOME/Serlinolab/team/.git" ]
  [ -d "$HOME/Serlinolab/Serlinolab_Brain/.git" ]
  [ -d "$HOME/Serlinolab/personal/brands" ]
  [ -d "$HOME/Serlinolab/personal/ideas" ]
  [ -d "$HOME/Serlinolab/personal/finds" ]
  [ -f "$HOME/Serlinolab/personal/README.md" ]
  [ -f "$HOME/Serlinolab/CLAUDE.md" ]
  [ -L "$HOME/Serlinolab/AGENTS.md" ]
  [ "$(readlink "$HOME/Serlinolab/AGENTS.md")" = CLAUDE.md ]
  [ "$(cat "$HOME/Serlinolab/.state/layout")" = parker-v2 ]
  [ -x "$HOME/Serlinolab/team/.git/hooks/pre-commit" ]
  [ -x "$HOME/Serlinolab/team/.git/hooks/pre-push" ]
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

  echo "a note" >> "$HOME/Serlinolab/team/note.txt"
  GIT_CONFIG_GLOBAL="$global_conf" BRAIN_ROOT="$HOME/Serlinolab" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$BRAIN_ROOT/hook_marker" ]

  printf 'ghp_%s\n' "$(printf 'a%.0s' $(seq 1 36))" > "$HOME/Serlinolab/team/secret.txt"
  GIT_CONFIG_GLOBAL="$global_conf" BRAIN_ROOT="$HOME/Serlinolab" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  grep -q "REJECT secret: secret.txt" "$HOME/Serlinolab/.state/sync.log"
}

# Review fix 2: a colleague can commit symlinks that point outside team/ (a credential
# directory, the read-only mirror, the signpost). Left as real symlinks, writing through them
# escapes team/. core.symlinks=false on the team clone makes git materialize them as small
# plain files holding the target text instead.
@test "a colleague's symlinks materialize as plain files, never real symlinks" {
  local teamwork; teamwork="$(mktemp -d)"
  "$REAL_GIT" clone -q "$BRAIN_ROOT/repos/team.git" "$teamwork"
  ln -s ../../.ssh "$teamwork/keys"
  ln -s ../Serlinolab_Brain "$teamwork/brain"
  ln -s ../CLAUDE.md "$teamwork/note"
  git -C "$teamwork" add -A
  git -C "$teamwork" -c user.name=fixture -c user.email=fixture@example.com commit -qm "colleague adds symlinks"
  git -C "$teamwork" push -q origin main
  rm -rf "$teamwork"

  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]

  echo "a note" >> "$HOME/Serlinolab/team/note2.txt"
  BRAIN_ROOT="$HOME/Serlinolab" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]

  run find "$HOME/Serlinolab/team" -type l
  [ -z "$output" ]
  [ -f "$HOME/Serlinolab/team/keys" ]
  [ "$(cat "$HOME/Serlinolab/team/keys")" = "../../.ssh" ]
  [ -f "$HOME/Serlinolab/team/note" ]
  [ "$(cat "$HOME/Serlinolab/team/note")" = "../CLAUDE.md" ]
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
  [ ! -e "$HOME/Serlinolab/team/CLAUDE.md" ]
  [ ! -e "$HOME/Serlinolab/team/.claude" ]
}

@test "a failed team clone configuration leaves no team clone at all, and setup reports the failure plainly" {
  push_colleague_instructions_to_team_origin
  FAIL_SPARSE=1 BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/Serlinolab/team" ]
  [[ "$output" == *"pending"* ]] || false
  [ ! -e "$HOME/Serlinolab/.state/setup-complete" ]
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
  local marker_before; marker_before=$(cat "$HOME/Serlinolab/.state/team-configured")

  push_colleague_instructions_to_team_origin
  rm -rf "$HOME/Serlinolab/team"
  # an ORDINARY clone - no sparse-checkout, no hooks, no core.symlinks=false - simulating a
  # replacement that never went through complete_setup at all
  "$REAL_GIT" clone -q "$BRAIN_ROOT/repos/team.git" "$HOME/Serlinolab/team"
  # the stale marker survives the replacement untouched, exactly as the finding describes
  [ "$(cat "$HOME/Serlinolab/.state/team-configured")" = "$marker_before" ]
  # proof the replacement is genuinely unprotected: an ordinary clone checked out everything,
  # including the colleague's instructions a sparse-checkout would have excluded
  [ -f "$HOME/Serlinolab/team/CLAUDE.md" ]

  BRAIN_ROOT="$HOME/Serlinolab" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]

  [ -x "$HOME/Serlinolab/team/.git/hooks/pre-commit" ]
  [ -x "$HOME/Serlinolab/team/.git/hooks/pre-push" ]
  [ "$(git -C "$HOME/Serlinolab/team" config core.hooksPath)" = "$HOME/Serlinolab/team/.git/hooks" ]
  [ "$(git -C "$HOME/Serlinolab/team" config core.symlinks)" = false ]
  # the sparse-checkout reapply that reconfiguration performs removes what should never have
  # been checked out in the first place
  [ ! -e "$HOME/Serlinolab/team/CLAUDE.md" ]
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
  "$REAL_GIT" clone -q "$BRAIN_ROOT/repos/team.git" "$HOME/Serlinolab/team"
  local before; before=$(git -C "$HOME/Serlinolab/team" rev-parse HEAD)

  push_colleague_instructions_to_team_origin

  FAIL_SPARSE=1 BRAIN_ROOT="$HOME/Serlinolab" run bash "$REPO_ROOT/sync.sh"
  # Codex review of aea244e, blocking finding 1: team_online() (lib/sync.sh) now probes team/'s
  # OWN remote independently of the mirror, so this fixture's genuinely-empty mirror.git (a
  # scaffolding artifact, never a deliberate "offline" simulation) no longer masks sync_team
  # actually being attempted here - it correctly runs and correctly skips (exit 2, "team folder
  # configuration is not complete"), which is a more honest signal than the old accidental 0.
  [ "$status" -eq 2 ]

  # never deleted - this run adopted it rather than cloning it itself
  [ -d "$HOME/Serlinolab/team/.git" ]
  # never fetched/rebased - the colleague's push never reached the local working tree
  [ "$(git -C "$HOME/Serlinolab/team" rev-parse HEAD)" = "$before" ]
  [ ! -e "$HOME/Serlinolab/team/CLAUDE.md" ]
  [ ! -e "$HOME/Serlinolab/team/.claude" ]
  grep -q "skipping this cycle" "$HOME/Serlinolab/.state/sync.log"
}

# MAX-1515 re-review, finding F1: team_is_protected used to check that the sparse-checkout
# CONFIGURATION was written (init ran, the pattern file has the right text) but never that it
# was actually APPLIED to the working tree. `sparse-checkout reapply` is the one step that
# strips an already-checked-out CLAUDE.md back out - fail ONLY that step (init and the pattern
# file both still succeed) and, before this fix, every check team_is_protected made still
# passed while CLAUDE.md sat on disk. A real setup.sh run first, so $STATE/engine/lib exists
# and install_team_hooks genuinely succeeds during the reconfigure attempt below - otherwise a
# missing-hooks failure would mask the exact gap this test means to prove.
@test "a sparse-checkout reapply failure blocks the whole cycle, and team_is_protected catches the CLAUDE.md it leaves behind" {
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]

  push_colleague_instructions_to_team_origin
  rm -rf "$HOME/Serlinolab/team"
  # an ORDINARY clone - no sparse-checkout, no hooks - simulating a replacement that never went
  # through complete_setup at all, exactly like the stale-marker test above, but this one
  # already has the colleague's CLAUDE.md checked out because origin already carries it
  "$REAL_GIT" clone -q "$BRAIN_ROOT/repos/team.git" "$HOME/Serlinolab/team"
  local before; before=$(git -C "$HOME/Serlinolab/team" rev-parse HEAD)
  [ -f "$HOME/Serlinolab/team/CLAUDE.md" ]

  FAIL_SPARSE_REAPPLY=1 BRAIN_ROOT="$HOME/Serlinolab" run bash "$REPO_ROOT/sync.sh"
  # Codex review of aea244e, blocking finding 1: team_online() (lib/sync.sh) probes team/'s own
  # remote independently of the mirror now, so sync_team IS reached this cycle - but its very
  # first check (finding F1b, `setup_rc -eq 3`) returns immediately, before any git operation
  # on team/, giving the more honest exit 2 ("skip") instead of an exit 0 that used to depend
  # on this fixture's unrelated, always-empty mirror.git happening to gate the whole cycle.
  [ "$status" -eq 2 ]

  # never fetched/rebased, never staged/committed a colleague's push onto an unprotected team/
  [ "$(git -C "$HOME/Serlinolab/team" rev-parse HEAD)" = "$before" ]
  grep -q "skipping this cycle's team folder operations" "$HOME/Serlinolab/.state/sync.log"
  # the exact gap the finding names: reapply never ran, so CLAUDE.md is still there
  [ -f "$HOME/Serlinolab/team/CLAUDE.md" ]

  # finding F1a, checked directly: with every OTHER check (hooksPath, symlinks, sparse config
  # text, installed hooks, HEAD) genuinely passing, team_is_protected must still refuse solely
  # because CLAUDE.md is on disk.
  run env STATE="$HOME/Serlinolab/.state" EXPECTED_TEAM_REMOTE='git@brain-team:serlinolab/brain-team.git' \
    bash -c "source '$REPO_ROOT/lib/complete_setup.sh'; team_is_protected '$HOME/Serlinolab/team'"
  [ "$status" -ne 0 ]
}

# MAX-1515 re-review, finding F4: lib/complete_setup.sh's own remote_matches (distinct from
# lib/sync.sh's remote_matches_expected, which fix 2 already covers) used to read the push-url
# enumeration through a bare `while read < <(...)`, hiding a failing git call - 0 lines of
# output looked exactly like "every push URL matched". team_is_protected relies on this same
# function; inject the failure into a real, fully-configured team/ so nothing else in the check
# chain is what fails.
@test "a failing push-url enumeration makes team_is_protected refuse, not silently pass" {
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]

  local fakebin; fakebin="$(mktemp -d)"
  cat > "$fakebin/git" <<EOF
#!/bin/bash
case "\$*" in
  *"remote get-url --push --all origin"*)
    echo "fatal: injected failure" >&2
    exit 128
    ;;
esac
exec "$HOME/bin/git" "\$@"
EOF
  chmod +x "$fakebin/git"

  PATH="$fakebin:$HOME/bin:$PATH" run env STATE="$HOME/Serlinolab/.state" \
    EXPECTED_TEAM_REMOTE='git@brain-team:serlinolab/brain-team.git' \
    bash -c "source '$REPO_ROOT/lib/complete_setup.sh'; team_is_protected '$HOME/Serlinolab/team'"
  [ "$status" -ne 0 ]
}

# Finding A: setup.sh and a background sync cycle both call complete_setup. Before this fix,
# only sync.sh took the lock - the two could run complete_setup at the same moment, and the
# loser's failed-clone cleanup (an unconditional rm -rf) could delete whichever side actually
# finished. setup.sh now takes the same lock, so the two can never be inside complete_setup
# together in the first place.
# MAX-1515 re-review, finding F5: replaces the two guessed sleep durations (a 0.5s hold, a
# 0.15s wait to let the background cycle "probably" have the lock by then) with an explicit
# rendezvous on real state - the holder creates a ready file the instant it actually holds the
# lock, and only releases it once this test says to (a release file), so the collision is
# certain rather than merely likely under normal test-machine load.
@test "setup.sh never runs complete_setup while a background cycle holds the lock" {
  # Pre-seed the layout/person state a first setup.sh run would have written, so this test's
  # OWN concurrent processes race only on the lock - not on setup.sh's unrelated AC-8 "not
  # made by this setup" guard, which would otherwise fire the instant the background cycle's
  # own `mkdir -p $STATE` (lib/common.sh) creates $ROOT first.
  mkdir -p "$HOME/Serlinolab/.state"
  printf 'parker-v2\n' > "$HOME/Serlinolab/.state/layout"
  printf 'alice\n' > "$HOME/Serlinolab/.state/person"

  local ready="$BRAIN_ROOT/holder-ready" release="$BRAIN_ROOT/holder-release"
  BRAIN_ROOT="$HOME/Serlinolab" SYNC_HOLD_READY_FILE="$ready" SYNC_HOLD_RELEASE_FILE="$release" \
    bash "$REPO_ROOT/sync.sh" &
  local holder=$!
  local waited=0
  while [ ! -e "$ready" ]; do
    sleep 0.02
    waited=$((waited + 1))
    [ "$waited" -lt 500 ] || { echo "holder never signalled ready" >&2; false; }
  done
  [ -d "$HOME/Serlinolab/.state/run.lock" ]

  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  : > "$release"   # let the holder proceed with the rest of its cycle now that the collision
                    # setup.sh just hit has already run to completion
  wait "$holder"

  # the collision was detected and never raced into complete_setup together - whichever side
  # actually finished configuring it, team/ ends up pointed at the real origin, never a
  # corrupted half-clone from two attempts stepping on each other
  [[ "$output" == *"already being completed in the background"* ]] || false
  [ -d "$HOME/Serlinolab/team/.git" ]
  [ "$(git -C "$HOME/Serlinolab/team" remote get-url origin)" = 'git@brain-team:serlinolab/brain-team.git' ]
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

  mkdir -p "$HOME/Serlinolab/.state"
  printf 'parker-v2\n' > "$HOME/Serlinolab/.state/layout"
  printf 'testperson\n' > "$HOME/Serlinolab/.state/person"
  PATH="$fakebin:$HOME/bin:$PATH" BRAIN_ROOT="$HOME/Serlinolab" run bash "$REPO_ROOT/sync.sh"

  # Codex review of aea244e, blocking finding 1: the winner's clone that materializes here is
  # never actually configured (complete_setup's clone step reported failure to THIS attempt, so
  # it never reached the configure block) - team_online() now correctly finds team/'s own
  # remote reachable and lets sync_team run, which correctly refuses an unprotected team/ (exit
  # 2), rather than exit 0 riding on this fixture's unrelated, always-empty mirror.git.
  [ "$status" -eq 2 ]
  [ -d "$HOME/Serlinolab/team/.git" ]
  [ "$(cd "$HOME/Serlinolab/team" && git remote get-url origin)" = 'git@brain-team:serlinolab/brain-team.git' ]
  [[ "$output" == *"already completed elsewhere"* ]] || false
}

# MAX-1515 re-review, finding F3: the sibling test above proves a concurrent winner's clone of
# the SAME remote survives. This proves the harder case named by the finding - a directory that
# has nothing to do with this protocol at all must survive too, not just get treated as "someone
# else's real clone" and left alone for that reason. Before the fix, `remote_matches` false
# (foreign origin) sent this straight to an unconditional `rm -rf`. Simulated the same way the
# sibling test simulates its race: the stubbed `git clone` call plants a foreign repo as its own
# side effect, in place of doing a real clone, then reports failure - standing in for "a foreign
# directory appeared at team/ between the ownership check (mkdir) and the clone" as closely as a
# deterministic test can.
@test "a foreign directory that appears during a losing clone attempt survives untouched" {
  local fakebin; fakebin="$(mktemp -d)"
  cat > "$fakebin/git" <<EOF
#!/bin/bash
if [ "\$1" = clone ]; then
  "\$REAL_GIT" init -q "$HOME/Serlinolab/team"
  "\$REAL_GIT" -C "$HOME/Serlinolab/team" remote add origin https://unrelated.example/foreign.git
  exit 1
fi
exec "$HOME/bin/git" "\$@"
EOF
  chmod +x "$fakebin/git"

  mkdir -p "$HOME/Serlinolab/.state"
  printf 'parker-v2\n' > "$HOME/Serlinolab/.state/layout"
  printf 'testperson\n' > "$HOME/Serlinolab/.state/person"
  PATH="$fakebin:$HOME/bin:$PATH" BRAIN_ROOT="$HOME/Serlinolab" run bash "$REPO_ROOT/sync.sh"

  # a foreign origin at team/ is refused, same as everywhere else in this file (e.g. "a
  # background cycle facing a foreign team origin never adopts it") - commit_local's own
  # remote_matches_expected check catches it and stops the cycle before the network. The F3
  # invariant under test is what survives, not this status.
  [ "$status" -ne 0 ]
  # never removed - this attempt only ever owned the empty directory its own mkdir created, not
  # whatever ended up inside it
  [ -d "$HOME/Serlinolab/team/.git" ]
  [ "$(cd "$HOME/Serlinolab/team" && git remote get-url origin)" = 'https://unrelated.example/foreign.git' ]
}

@test "setup never overwrites an existing personal README" {
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  printf 'my own words\n' > "$HOME/Serlinolab/personal/README.md"
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/Serlinolab/personal/README.md")" = 'my own words' ]
}

# AC-8
@test "setup refuses to touch a pre-existing folder it did not create (the MAX-1514 layout)" {
  mkdir -p "$HOME/Serlinolab/.state"
  date -u +%FT%TZ > "$HOME/Serlinolab/.state/setup-complete"   # old layout: has this, never had .state/layout
  mkdir -p "$HOME/Serlinolab/personal/shared" "$HOME/Serlinolab/Serlinolab_Brain"
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"was not made by this setup"* ]] || false
  [ ! -d "$HOME/Serlinolab/team" ]
  [ ! -f "$HOME/Serlinolab/CLAUDE.md" ]
}

@test "setup refuses a hand-made ~/Serlinolab folder" {
  mkdir -p "$HOME/Serlinolab/whatever"
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"was not made by this setup"* ]] || false
  [ ! -d "$HOME/Serlinolab/.state" ]
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
  [ -f "$HOME/Serlinolab/.state/setup-started" ]
  [ ! -e "$HOME/Serlinolab/team" ]
  [ ! -e "$HOME/Serlinolab/Serlinolab_Brain" ]
}

# (b)
@test "a later sync cycle completes setup once the keys are simulated as registered, with no user action" {
  FAIL_TEAM=1 BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/Serlinolab/team" ]
  [ ! -e "$HOME/Serlinolab/Serlinolab_Brain" ]

  push_colleague_instructions_to_team_origin

  # the key is now "registered" - the fake git wrapper no longer fails the team clone
  BRAIN_ROOT="$HOME/Serlinolab" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  [ -d "$HOME/Serlinolab/team/.git" ]
  [ -d "$HOME/Serlinolab/Serlinolab_Brain/.git" ]
  [ -x "$HOME/Serlinolab/team/.git/hooks/pre-commit" ]
  [ -x "$HOME/Serlinolab/team/.git/hooks/pre-push" ]
  [ "$(git -C "$HOME/Serlinolab/team" config core.hooksPath)" = "$HOME/Serlinolab/team/.git/hooks" ]
  [ "$(git -C "$HOME/Serlinolab/team" config core.symlinks)" = false ]
  [ -f "$HOME/Serlinolab/.state/team-configured" ]
  [ -f "$HOME/Serlinolab/.state/setup-complete" ]
  [ ! -e "$HOME/Serlinolab/team/CLAUDE.md" ]
  [ ! -e "$HOME/Serlinolab/team/.claude" ]
}

# (c)
@test "a completed setup is left untouched by later cycles - no reclone, no config or hook drift" {
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  local before_config before_precommit before_prepush before_team_inode before_mirror_inode
  before_config=$(git -C "$HOME/Serlinolab/team" config --list)
  before_precommit=$(shasum "$HOME/Serlinolab/team/.git/hooks/pre-commit")
  before_prepush=$(shasum "$HOME/Serlinolab/team/.git/hooks/pre-push")
  before_team_inode=$(stat -f %i "$HOME/Serlinolab/team/.git")
  before_mirror_inode=$(stat -f %i "$HOME/Serlinolab/Serlinolab_Brain/.git")

  BRAIN_ROOT="$HOME/Serlinolab" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  BRAIN_ROOT="$HOME/Serlinolab" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]

  [ "$(git -C "$HOME/Serlinolab/team" config --list)" = "$before_config" ]
  [ "$(shasum "$HOME/Serlinolab/team/.git/hooks/pre-commit")" = "$before_precommit" ]
  [ "$(shasum "$HOME/Serlinolab/team/.git/hooks/pre-push")" = "$before_prepush" ]
  # an inode unchanged across two cycles proves complete_setup never re-cloned - a clone would
  # recreate .git under a fresh inode
  [ "$(stat -f %i "$HOME/Serlinolab/team/.git")" = "$before_team_inode" ]
  [ "$(stat -f %i "$HOME/Serlinolab/Serlinolab_Brain/.git")" = "$before_mirror_inode" ]
}

# (d)
@test "still pending past SETUP_PENDING_ALERT_HOURS raises the attention file in plain words, cleared once complete" {
  FAIL_TEAM=1 BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]

  SETUP_PENDING_ALERT_HOURS=0 FAIL_TEAM=1 BRAIN_ROOT="$HOME/Serlinolab" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  [ -f "$HOME/Serlinolab/SOMETHING NEEDS YOUR ATTENTION.txt" ]
  grep -qi "not ready yet" "$HOME/Serlinolab/SOMETHING NEEDS YOUR ATTENTION.txt"
  run grep -inE '\b(git|repo|repository|commit|push|pull|branch|clone|merge|PR|key|SSH)\b' "$HOME/Serlinolab/SOMETHING NEEDS YOUR ATTENTION.txt"
  [ "$status" -ne 0 ]

  BRAIN_ROOT="$HOME/Serlinolab" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/Serlinolab/SOMETHING NEEDS YOUR ATTENTION.txt" ]
}

# (e)
@test "personal/ is never touched by a pending or a completing background setup cycle" {
  FAIL_TEAM=1 BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  mkdir -p "$HOME/Serlinolab/personal/ideas"
  echo "my plan" > "$HOME/Serlinolab/personal/ideas/plan.txt"
  local before_mtime
  before_mtime=$(stat -f %m "$HOME/Serlinolab/personal/ideas/plan.txt")

  FAIL_TEAM=1 BRAIN_ROOT="$HOME/Serlinolab" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  BRAIN_ROOT="$HOME/Serlinolab" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]

  [ "$(cat "$HOME/Serlinolab/personal/ideas/plan.txt")" = "my plan" ]
  [ "$(stat -f %m "$HOME/Serlinolab/personal/ideas/plan.txt")" = "$before_mtime" ]
  [ ! -d "$HOME/Serlinolab/personal/.git" ]
  [ ! -d "$HOME/Serlinolab/personal/ideas/.git" ]
}

# (f)
@test "a background cycle facing a foreign team origin never adopts it, and raises the attention marker" {
  FAIL_TEAM=1 BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/Serlinolab/team" ]
  git init -q "$HOME/Serlinolab/team"
  git -C "$HOME/Serlinolab/team" remote add origin https://unrelated.example/team.git

  BRAIN_ROOT="$HOME/Serlinolab" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -ne 0 ]
  [ "$(git -C "$HOME/Serlinolab/team" remote get-url origin)" = "https://unrelated.example/team.git" ]
  [ ! -f "$HOME/Serlinolab/.state/team-configured" ]
  [ -f "$HOME/Serlinolab/SOMETHING NEEDS YOUR ATTENTION.txt" ]
  grep -qi "not connected to where it should be" "$HOME/Serlinolab/SOMETHING NEEDS YOUR ATTENTION.txt"
}

# `read -r -p "..." PERSON < /dev/tty 2>/dev/null` sends the prompt to stderr (that's what `-p`
# does), and the `2>/dev/null` on the read threw it away - a creator piping the README's own
# `curl | bash` line saw a silent, frozen terminal and no question at all (hit live by Max,
# 2026-09-23). Bats gives every test a pipe for stdin/stdout, never a real tty, so this cannot be
# proven end to end here - it is a static proof instead: the question is printed to /dev/tty by
# this script's own printf (never by `read -p`, whose prompt goes to stderr), and the `read` that
# follows it carries no `2>/dev/null` that could ever swallow a prompt again.
@test "the name prompt is printed to /dev/tty directly, and the read that follows it is never redirected to /dev/null" {
  run grep -n 'Your first name' "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"it signs the notes you share in team/"* ]] || false
  [[ "$output" == *"> /dev/tty"* ]] || false

  run grep -n 'read -r PERSON' "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"< /dev/tty"* ]] || false
  [[ "$output" != *"2>/dev/null"* ]] || false
  [[ "$output" != *" -p "* ]] || false
}
