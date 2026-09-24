REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

brain_test_setup() {
  BRAIN_ROOT="$(mktemp -d)"; export BRAIN_ROOT
  HOME="$(mktemp -d)"; export HOME
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/no-such-remote"; export ONLINE_CHECK_REMOTE
  ROOT="$BRAIN_ROOT"; STATE="$ROOT/.state"; TEAM="$ROOT/team"; MIRROR="$ROOT/Serlinolab_Brain"
  PERSONAL="$ROOT/personal"; MARK="$ROOT/SOMETHING NEEDS YOUR ATTENTION.txt"
  LOCK="$STATE/run.lock"; LOG="$STATE/sync.log"; CONFLICT_STATE="$STATE/conflict_attempts"
  CONFLICTS="$STATE/conflicts"; QUARANTINE="$STATE/quarantine"
  MAX_CONFLICT_ATTEMPTS=3
  # MAX-1515 fix 4b: the engine checks TEAM/MIRROR's actual origin against these before every
  # mutating operation. Tests never use the real git@brain-team/git@brain-mirror aliases -
  # make_fake_team_repo/make_fake_mirror below always seed $BRAIN_ROOT/origin-{team,mirror}.git
  # - so that has to be what "expected" means here too, the same way ONLINE_CHECK_REMOTE above
  # is overridden to a test double's URL rather than the real one.
  EXPECTED_TEAM_REMOTE="$BRAIN_ROOT/origin-team.git"
  EXPECTED_MIRROR_REMOTE="$BRAIN_ROOT/origin-mirror.git"
  export ROOT STATE TEAM MIRROR PERSONAL MARK LOCK LOG CONFLICT_STATE CONFLICTS QUARANTINE MAX_CONFLICT_ATTEMPTS
  export EXPECTED_TEAM_REMOTE EXPECTED_MIRROR_REMOTE
  mkdir -p "$STATE"
  printf 'testperson\n' > "$STATE/person"   # setup.sh writes this on a real Mac
}

brain_test_teardown() {
  chmod -R u+w "$BRAIN_ROOT" "$HOME" 2>/dev/null || true
  rm -rf "$BRAIN_ROOT" "$HOME"
}

git_commit() {
  git -C "$1" -c user.name=fixture -c user.email=fixture@example.com commit -q -m "${2:-fixture}"
}

seed_repo() {
  local origin="$1" dest="$2" file="$3" tmp; tmp="$(mktemp -d)"
  git init -q --bare "$origin"; git init -q -b main "$tmp"
  mkdir -p "$(dirname "$tmp/$file")"; echo hello > "$tmp/$file"
  git -C "$tmp" add -A; git_commit "$tmp" init
  git -C "$tmp" remote add origin "$origin"; git -C "$tmp" push -q origin main
  mkdir -p "$(dirname "$dest")"; git clone -q "$origin" "$dest"; rm -rf "$tmp"
}

# MAX-1515 (amended): the two-way repo is $TEAM (team/); the read-only mirror is $ROOT/Serlinolab_Brain,
# beside team/, not nested inside it. make_fake_team_repo replaces make_fake_personal_repo.
#
# MAX-1515 review finding D: a marker written up front (without doing the configuration it
# claims) hid the exact bug finding B found - team_is_protected (lib/complete_setup.sh) is now
# the real gate, so a fixture that only sets the marker would leave team_is_protected false and
# every test using it would see its commits/pushes skipped. This calls the SAME configuration
# steps complete_setup itself calls (through team_layout.sh / secretscan.sh, never a hand
# rolled copy), against the SAME libdir convention ($STATE/engine/lib) team_is_protected checks
# hooks against - seeded here with the one file those hooks actually source at runtime, so a
# real commit through them still works. A test can no longer pass against a clone the
# production code would itself refuse to trust.
make_fake_team_repo() {
  seed_repo "$BRAIN_ROOT/origin-team.git" "$TEAM" note.txt
  mkdir -p "$STATE/engine/lib"
  cp "$REPO_ROOT/lib/secretscan.sh" "$STATE/engine/lib/secretscan.sh"
  git -C "$TEAM" config core.hooksPath "$TEAM/.git/hooks"
  git -C "$TEAM" config core.symlinks false
  configure_team_sparse_checkout
  # shellcheck source=../lib/team_layout.sh
  source "$REPO_ROOT/lib/team_layout.sh"
  write_team_exclude "$TEAM"
  install_test_team_hooks "$STATE/engine/lib"
  date -u +%FT%TZ > "$STATE/team-configured"
}
make_fake_mirror() { mkdir -p "$ROOT"; seed_repo "$BRAIN_ROOT/origin-mirror.git" "$MIRROR" sub/file.txt; ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-mirror.git"; export ONLINE_CHECK_REMOTE; run_sync_cycle; }
make_local_ahead_change() { echo 'unsent note' >> "$TEAM/note.txt"; }
run_sync_cycle() { bash "$REPO_ROOT/sync.sh"; }

make_fake_brain_sync_origin() {
  FAKE_ORIGIN="$BRAIN_ROOT/origin-brain-sync.git"; export FAKE_ORIGIN
  BRAIN_SYNC_WORK="$(mktemp -d)"; export BRAIN_SYNC_WORK
  git init -q --bare "$FAKE_ORIGIN"
  git init -q -b main "$BRAIN_SYNC_WORK"; mkdir -p "$BRAIN_SYNC_WORK/lib"
  printf '#!/bin/bash\n[ "${1:-}" = "--selfcheck" ] && exit 0\nexit 0\n' > "$BRAIN_SYNC_WORK/sync.sh"
  printf '#!/bin/bash\n: stub\n' > "$BRAIN_SYNC_WORK/lib/common.sh"
  git -C "$BRAIN_SYNC_WORK" add -A; git_commit "$BRAIN_SYNC_WORK" 'good engine'
  git -C "$BRAIN_SYNC_WORK" remote add origin "$FAKE_ORIGIN"; git -C "$BRAIN_SYNC_WORK" push -q origin main
}

# AC-4: installs the SAME sparse-checkout + local exclude setup.sh installs on a real Mac -
# lib/team_layout.sh is the one place that pattern is written, sourced by both setup.sh and
# this helper, so a test can never assert against a pattern setup.sh does not actually ship.
configure_team_sparse_checkout() {
  # shellcheck source=../lib/team_layout.sh
  source "$REPO_ROOT/lib/team_layout.sh"
  write_team_sparse_checkout "$TEAM"
}

# Class B: installs the SAME pre-commit/pre-push hooks setup.sh installs - lib/secretscan.sh
# is the one place their bodies are written, so a test can never assert against a hook body
# setup.sh does not actually ship. $1 (optional) overrides the library directory the hooks
# source; defaults to the repo's own lib/, which is what a real Mac's cloned engine copy at
# .state/engine/lib would contain.
install_test_team_hooks() {
  # shellcheck source=../lib/secretscan.sh
  source "$REPO_ROOT/lib/secretscan.sh"
  install_team_hooks "$TEAM" "${1:-$REPO_ROOT/lib}"
}

# A second Mac's own team/ clone against the SAME origin-team.git bare remote as $TEAM - for
# tests that need two real Macs syncing concurrently (2026-09-24 OS-junk/dirty-tree incident).
# Sets ROOT2/STATE2/TEAM2. Run a cycle on it with `run_second_mac_sync_cycle` -
# ONLINE_CHECK_REMOTE/EXPECTED_TEAM_REMOTE/EXPECTED_MIRROR_REMOTE stay whatever the test
# already exported (process-wide), since both Macs point at the same real remotes.
setup_second_team_clone() {
  ROOT2="$(mktemp -d)"; export ROOT2
  STATE2="$ROOT2/.state"; TEAM2="$ROOT2/team"; export STATE2 TEAM2
  mkdir -p "$STATE2/engine/lib"
  printf 'karl\n' > "$STATE2/person"
  cp "$REPO_ROOT/lib/secretscan.sh" "$STATE2/engine/lib/secretscan.sh"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$TEAM2"
  git -C "$TEAM2" config core.hooksPath "$TEAM2/.git/hooks"
  git -C "$TEAM2" config core.symlinks false
  ( TEAM="$TEAM2" configure_team_sparse_checkout )
  ( TEAM="$TEAM2" install_test_team_hooks "$STATE2/engine/lib" )
  date -u +%FT%TZ > "$STATE2/team-configured"
}
run_second_mac_sync_cycle() { BRAIN_ROOT="$ROOT2" bash "$REPO_ROOT/sync.sh"; }

break_origin_sync_sh() {
  printf '#!/bin/bash\nexit 1\n' > "$BRAIN_SYNC_WORK/sync.sh"
  git -C "$BRAIN_SYNC_WORK" add sync.sh; git_commit "$BRAIN_SYNC_WORK" 'broken engine'; git -C "$BRAIN_SYNC_WORK" push -q origin main
}
