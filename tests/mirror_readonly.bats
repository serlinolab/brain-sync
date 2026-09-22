#!/usr/bin/env bats
# AC-2 - regression: mirror directories stayed writable on the prototype,
# so a creator's new file was silently eaten by the next clean.
load 'helpers'
setup() { brain_test_setup; make_fake_mirror; }
teardown() { brain_test_teardown; }

@test "creating a new file inside a mirror directory fails" {
  run bash -c "echo hi > '$MIRROR/sub/newfile.txt'" 2>/dev/null
  [ "$status" -ne 0 ]
  [ ! -e "$MIRROR/sub/newfile.txt" ]
}

@test "creating a new file at the mirror root fails" {
  run bash -c "echo hi > '$MIRROR/root-file.txt'" 2>/dev/null
  [ "$status" -ne 0 ]
  [ ! -e "$MIRROR/root-file.txt" ]
}

@test "a fetch that fails on the very first cycle still leaves the mirror protected" {
  # The test below reaches this path AFTER a successful cycle has already protected the tree,
  # so removing the failure branch's protect_readonly changed nothing and the mutation stayed
  # green. A freshly cloned mirror has never been protected: if its first fetch fails and the
  # branch is missing, the whole company folder is left writable, and whatever the creator
  # then writes into it dies in the next successful reset --hard.
  local root; root="$(mktemp -d)"
  seed_repo "$root/origin.git" "$root/serlinolab" sub/file.txt
  git -C "$root/serlinolab" remote set-url origin "$root/missing-origin.git"
  BRAIN_ROOT="$root" MIRROR="$root/serlinolab" run bash -c \
    "source '$REPO_ROOT/lib/common.sh'; source '$REPO_ROOT/lib/sync.sh'; MIRROR='$root/serlinolab'; sync_mirror"
  local fetch_status=$status
  run bash -c "echo hi > '$root/serlinolab/sub/file.txt'"
  local write_status=$status
  chmod -R u+w "$root" 2>/dev/null || true
  rm -rf "$root"
  [ "$fetch_status" -ne 0 ]
  [ "$write_status" -ne 0 ]
}

@test "a failed mirror fetch leaves the mirror protected" {
  git -C "$MIRROR" remote set-url origin "$BRAIN_ROOT/missing-origin.git"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-mirror.git" run bash "$REPO_ROOT/sync.sh"
  run bash -c "echo hi > '$MIRROR/after-failed-fetch.txt'" 2>/dev/null
  [ "$status" -ne 0 ]
}

@test "mkdir inside a mirror directory fails" {
  run mkdir "$MIRROR/sub/newdir"
  [ "$status" -ne 0 ]
  [ ! -d "$MIRROR/sub/newdir" ]
}

@test "editing an existing tracked mirror file fails" {
  run bash -c "echo changed > '$MIRROR/sub/file.txt'" 2>/dev/null
  [ "$status" -ne 0 ]
  [ "$(cat "$MIRROR/sub/file.txt")" = hello ]
}

@test "a sync cycle against a mirror whose origin was changed to another repo leaves it untouched and raises the marker" {
  # MAX-1515 fix 4b: a refused/adopted-then-swapped mirror must never be reset/cleaned just
  # because it sits at the expected path - the origin itself is re-checked every cycle.
  chmod -R u+w "$MIRROR"
  echo stray > "$MIRROR/stray.txt"
  git -C "$MIRROR" remote set-url origin "$BRAIN_ROOT/some-other-repo.git"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-mirror.git" run bash "$REPO_ROOT/sync.sh"
  [ -e "$MIRROR/stray.txt" ]   # never cleaned - sync_mirror skipped this repo entirely
  grep -qi "company folder" "$MARK"   # plain words, not git vocabulary - see AC-8
}

@test "a file cannot be created during the protected fetch window" {
  local fakebin real_git
  fakebin="$(mktemp -d)"; real_git="$(type -P git)"
  cat > "$fakebin/git" <<'SCRIPT'
#!/bin/bash
"$REAL_GIT" "$@"
if [ "$1" = "-C" ] && [ "$3" = fetch ]; then
  if echo race > "$MIRROR/race.txt"; then touch "$BRAIN_ROOT/race-created"; fi
fi
SCRIPT
  chmod +x "$fakebin/git"
  REAL_GIT="$real_git" PATH="$fakebin:$PATH" ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-mirror.git" \
    run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$BRAIN_ROOT/race-created" ]
  [ ! -e "$MIRROR/race.txt" ]
}
