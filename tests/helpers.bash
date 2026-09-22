REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

brain_test_setup() {
  BRAIN_ROOT="$(mktemp -d)"; export BRAIN_ROOT
  HOME="$(mktemp -d)"; export HOME
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/no-such-remote"; export ONLINE_CHECK_REMOTE
  ROOT="$BRAIN_ROOT"; STATE="$ROOT/.state"; TEAM="$ROOT/team"; MIRROR="$TEAM/serlinolab"
  PERSONAL="$ROOT/personal"; MARK="$ROOT/SOMETHING NEEDS YOUR ATTENTION.txt"
  LOCK="$STATE/run.lock"; LOG="$STATE/sync.log"; CONFLICT_STATE="$STATE/conflict_attempts"
  CONFLICTS="$STATE/conflicts"; QUARANTINE="$STATE/quarantine"
  MAX_CONFLICT_ATTEMPTS=3
  export ROOT STATE TEAM MIRROR PERSONAL MARK LOCK LOG CONFLICT_STATE CONFLICTS QUARANTINE MAX_CONFLICT_ATTEMPTS
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

# MAX-1515: the two-way repo is now $TEAM (team/), with the read-only mirror nested inside it
# at $TEAM/serlinolab. make_fake_team_repo replaces make_fake_personal_repo.
make_fake_team_repo() { seed_repo "$BRAIN_ROOT/origin-team.git" "$TEAM" note.txt; }
make_fake_mirror() { mkdir -p "$TEAM"; seed_repo "$BRAIN_ROOT/origin-mirror.git" "$MIRROR" sub/file.txt; ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-mirror.git"; export ONLINE_CHECK_REMOTE; run_sync_cycle; }
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

break_origin_sync_sh() {
  printf '#!/bin/bash\nexit 1\n' > "$BRAIN_SYNC_WORK/sync.sh"
  git -C "$BRAIN_SYNC_WORK" add sync.sh; git_commit "$BRAIN_SYNC_WORK" 'broken engine'; git -C "$BRAIN_SYNC_WORK" push -q origin main
}
