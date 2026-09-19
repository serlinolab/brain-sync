# Shared bats setup. Every test uses a throwaway BRAIN_ROOT and real local
# git repos (bare "origin" + clone) over file:// instead of SSH/GitHub.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

brain_test_setup() {
  BRAIN_ROOT="$(mktemp -d)"; export BRAIN_ROOT
  export ONLINE_CHECK_REMOTE="$BRAIN_ROOT/no-such-remote"  # unreachable -> fails fast, no real timeout
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/sync.sh"
}

brain_test_teardown() {
  chmod -R u+w "$BRAIN_ROOT" 2>/dev/null || true   # AC-2 leaves dirs read-only
  rm -rf "$BRAIN_ROOT"
}

# Bare "origin" seeded with one file, cloned into $2 - what sync_mirror and
# sync_personal each expect to find.
seed_repo() {
  local origin="$1" dest="$2" file="$3" tmp; tmp="$(mktemp -d)"
  git init -q --bare "$origin"; git init -q -b main "$tmp"
  mkdir -p "$(dirname "$tmp/$file")"; echo "hello" > "$tmp/$file"
  git -C "$tmp" add -A && git -C "$tmp" commit -q -m init
  git -C "$tmp" remote add origin "$origin" && git -C "$tmp" push -q origin main
  mkdir -p "$(dirname "$dest")"; git clone -q "$origin" "$dest"; rm -rf "$tmp"
}

make_fake_personal_repo() { seed_repo "$BRAIN_ROOT/origin-personal.git" "$PERSONAL" note.txt; }
make_fake_mirror() { seed_repo "$BRAIN_ROOT/origin-mirror.git" "$MIRROR" sub/file.txt; sync_mirror; }
make_local_ahead_change() { echo "unsent note" >> "$PERSONAL/note.txt"; }
run_sync_cycle() { bash "$REPO_ROOT/sync.sh"; }

# AC-9 fixture: a local "brain-sync" origin seeded with a real, working copy.
make_fake_brain_sync_origin() {
  FAKE_ORIGIN="$BRAIN_ROOT/origin-brain-sync.git"; export FAKE_ORIGIN
  BRAIN_SYNC_WORK="$(mktemp -d)"; export BRAIN_SYNC_WORK
  git init -q --bare "$FAKE_ORIGIN"
  git init -q -b main "$BRAIN_SYNC_WORK"; mkdir -p "$BRAIN_SYNC_WORK/lib"
  printf '#!/bin/bash\n[ "${1:-}" = "--selfcheck" ] && exit 0\nexit 0\n' > "$BRAIN_SYNC_WORK/sync.sh"
  printf '#!/bin/bash\n: stub\n' > "$BRAIN_SYNC_WORK/lib/common.sh"
  git -C "$BRAIN_SYNC_WORK" add -A && git -C "$BRAIN_SYNC_WORK" commit -q -m "good engine"
  git -C "$BRAIN_SYNC_WORK" remote add origin "$FAKE_ORIGIN" && git -C "$BRAIN_SYNC_WORK" push -q origin main
}

break_origin_sync_sh() {
  printf '#!/bin/bash\nexit 1\n' > "$BRAIN_SYNC_WORK/sync.sh"
  git -C "$BRAIN_SYNC_WORK" commit -q -am "broken engine" && git -C "$BRAIN_SYNC_WORK" push -q origin main
}
