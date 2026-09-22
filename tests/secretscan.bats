#!/usr/bin/env bats
# AC-7 - a file that looks like it holds a secret never reaches the remote, whether it goes
# through the engine's own commit_local or a human commit/push protected by the installed
# git hooks. Neither rejection wedges the rest of the cycle. Fake secrets are built by
# concatenation at runtime so this file itself never contains a real-looking token.
#
# The hooks under test are installed by install_test_team_hooks (tests/helpers.bash), which
# calls the SAME install_team_hooks function setup.sh calls - so every test here exercises
# the hook body setup.sh actually ships, not a hand-copied reimplementation of it.
load 'helpers'
setup() { brain_test_setup; make_fake_team_repo; }
teardown() { brain_test_teardown; }

fake_github_pat() { printf 'ghp_%s\n' "$(printf 'a%.0s' $(seq 1 36))"; }
fake_sk_proj() { printf 'sk-proj-%s\n' "$(printf 'a%.0s' $(seq 1 80))"; }

@test "the engine rejects a secret-shaped file, logs and marks it, and still syncs every other file" {
  fake_github_pat > "$TEAM/secret.txt"
  echo "safe content" > "$TEAM/safe.txt"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  grep -q "REJECT secret: secret.txt" "$LOG"
  grep -q "secret.txt" "$MARK"
  git -C "$BRAIN_ROOT/origin-team.git" show main:safe.txt >/dev/null   # the other file made it
  run git -C "$BRAIN_ROOT/origin-team.git" show main:secret.txt
  [ "$status" -ne 0 ]   # the secret never reached the remote
}

@test "the pre-commit hook refuses a secret-shaped staged file directly" {
  install_test_team_hooks

  fake_github_pat > "$TEAM/secret.txt"
  git -C "$TEAM" add secret.txt
  run git -C "$TEAM" commit -qm 'oops'
  [ "$status" -ne 0 ]
  [[ "$output" == *"looks like it contains a secret"* ]] || false
  run git -C "$TEAM" log --oneline
  [[ "$output" != *oops* ]] || false
}

@test "the pre-commit hook scans the STAGED blob, not the working-tree copy that was later overwritten" {
  install_test_team_hooks

  fake_github_pat > "$TEAM/secret.txt"
  git -C "$TEAM" add secret.txt
  echo "harmless, edited after staging" > "$TEAM/secret.txt"   # working tree no longer looks like a secret
  run git -C "$TEAM" commit -qm 'still carries the staged secret'
  [ "$status" -ne 0 ]
  [[ "$output" == *"looks like it contains a secret"* ]] || false
}

@test "the pre-commit hook fails CLOSED when the secret-scan library cannot be loaded" {
  install_test_team_hooks "$BRAIN_ROOT/no-such-libdir"   # points the hook at a library that isn't there

  echo "totally ordinary content" > "$TEAM/ordinary.txt"
  git -C "$TEAM" add ordinary.txt
  run git -C "$TEAM" commit -qm 'should be refused'
  [ "$status" -ne 0 ]
  run git -C "$TEAM" log --oneline
  [[ "$output" != *"should be refused"* ]] || false
}

@test "the pre-push hook refuses a push that carries a secret even if it slipped past pre-commit" {
  install_test_team_hooks

  fake_github_pat > "$TEAM/secret.txt"
  git -C "$TEAM" add secret.txt
  git -C "$TEAM" -c user.name=t -c user.email=t@t.com commit --no-verify -qm 'bypassed pre-commit intentionally for this test'

  run git -C "$TEAM" push origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *"looks like it contains a secret"* ]] || false
  run git -C "$BRAIN_ROOT/origin-team.git" show main:secret.txt
  [ "$status" -ne 0 ]
}

@test "the pre-push hook scans every commit in the push range, not just the tree of the final commit" {
  install_test_team_hooks

  fake_github_pat > "$TEAM/secret.txt"
  git -C "$TEAM" add secret.txt
  git -C "$TEAM" -c user.name=t -c user.email=t@t.com commit --no-verify -qm 'introduces the secret'
  echo "replaced, this commit's tree looks clean" > "$TEAM/secret.txt"
  git -C "$TEAM" add secret.txt
  git -C "$TEAM" -c user.name=t -c user.email=t@t.com commit --no-verify -qm 'looks clean at HEAD'

  run git -C "$TEAM" push origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *"looks like it contains a secret"* ]] || false
  run git -C "$BRAIN_ROOT/origin-team.git" rev-parse main
  [ "$status" -ne 0 ] || [ "$output" != "$(git -C "$TEAM" rev-parse HEAD)" ]
}

@test "the pre-push hook fails CLOSED when the secret-scan library cannot be loaded" {
  install_test_team_hooks "$BRAIN_ROOT/no-such-libdir"

  echo "totally ordinary content" > "$TEAM/ordinary.txt"
  git -C "$TEAM" add ordinary.txt
  git -C "$TEAM" -c user.name=t -c user.email=t@t.com commit --no-verify -qm 'ordinary commit'
  run git -C "$TEAM" push origin main
  [ "$status" -ne 0 ]
  run git -C "$BRAIN_ROOT/origin-team.git" show main:ordinary.txt
  [ "$status" -ne 0 ]
}

@test "sk-proj- style keys (hyphens/underscores in the body) are detected" {
  install_test_team_hooks

  fake_sk_proj > "$TEAM/secret.txt"
  git -C "$TEAM" add secret.txt
  run git -C "$TEAM" commit -qm 'oops'
  [ "$status" -ne 0 ]
  [[ "$output" == *"looks like it contains a secret"* ]] || false
}

# --- AC-7 class review: blob-enumeration coverage (type-change, root, merge commits) ---

@test "the pre-push hook catches a secret introduced by a TYPE-CHANGE commit (diff-filter=ACMR excludes T)" {
  install_test_team_hooks

  ln -s /nonexistent "$TEAM/cred"
  git -C "$TEAM" add cred
  git -C "$TEAM" -c user.name=t -c user.email=t@t.com commit --no-verify -qm 'cred starts as a symlink'
  rm -f "$TEAM/cred"
  fake_github_pat > "$TEAM/cred"
  git -C "$TEAM" add cred
  # a path that changes kind (symlink -> regular file) at the same commit is reported by git
  # as Typechange (T), not Modified (M) - diff-filter=ACMR alone never sees this commit's blob
  run git -C "$TEAM" diff-tree -r --no-commit-id --diff-filter=ACMR --name-only HEAD^ -- cred
  [ -z "$output" ]
  git -C "$TEAM" -c user.name=t -c user.email=t@t.com commit --no-verify -qm 'cred becomes a regular file holding a secret'

  run git -C "$TEAM" push origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *"looks like it contains a secret"* ]] || false
  run git -C "$BRAIN_ROOT/origin-team.git" rev-parse main
  [ "$status" -ne 0 ] || [ "$output" != "$(git -C "$TEAM" rev-parse HEAD)" ]
}

@test "the pre-push hook catches a secret in the ROOT commit of a brand-new branch (diff-tree needs --root)" {
  local fresh; fresh="$(mktemp -d)"
  local fresh_origin="$BRAIN_ROOT/origin-fresh.git"
  git init -q --bare "$fresh_origin"
  git init -q -b main "$fresh"
  fake_github_pat > "$fresh/secret.txt"
  git -C "$fresh" add secret.txt
  git -C "$fresh" -c user.name=t -c user.email=t@t.com commit --no-verify -qm 'root commit carries a secret'
  git -C "$fresh" remote add origin "$fresh_origin"
  # a root commit (no parent) is invisible to `git diff-tree <sha>` without --root: this
  # single-commit push is exactly the "new branch" (remote sha all zeros) path.
  (source "$REPO_ROOT/lib/secretscan.sh"; install_team_hooks "$fresh" "$REPO_ROOT/lib")

  run git -C "$fresh" push origin main
  rm -rf "$fresh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"looks like it contains a secret"* ]] || false
  run git -C "$fresh_origin" rev-parse main
  [ "$status" -ne 0 ]
}

@test "the pre-push hook catches a secret introduced only by a MERGE commit (diff-tree needs -m)" {
  install_test_team_hooks

  # A two-parent commit whose tree adds secret.txt beyond EITHER parent's tree, built directly
  # with commit-tree (as a merge tool or a scripted rebase-like operation might produce) so
  # secret.txt never exists in any standalone, individually-diffable commit. Default (non -m)
  # diff-tree on a merge commit reports nothing for a change like this - the secret is only
  # visible in the merge's OWN combined diff, which -m produces.
  local B; B=$(git -C "$TEAM" rev-parse HEAD)
  echo unrelated > "$TEAM/unrelated.txt"
  git -C "$TEAM" add unrelated.txt
  git -C "$TEAM" -c user.name=t -c user.email=t@t.com commit --no-verify -qm 'B: unrelated change'
  local B2; B2=$(git -C "$TEAM" rev-parse HEAD)
  fake_github_pat > "$TEAM/secret.txt"
  git -C "$TEAM" add secret.txt
  local T; T=$(git -C "$TEAM" write-tree)
  git -C "$TEAM" reset -q -- secret.txt
  rm -f "$TEAM/secret.txt"
  local C; C=$(git -C "$TEAM" commit-tree "$T" -p "$B2" -p "$B" -m 'merge introduces a secret, no standalone commit does')
  git -C "$TEAM" update-ref refs/heads/main "$C"
  run git -C "$TEAM" diff-tree -r --no-commit-id --diff-filter=ACMR --name-only "$C"
  [ -z "$output" ]   # the merge commit's own diff-tree (without -m) never shows secret.txt

  run git -C "$TEAM" push origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *"looks like it contains a secret"* ]] || false
  run git -C "$BRAIN_ROOT/origin-team.git" show main:secret.txt
  [ "$status" -ne 0 ]
}

# --- AC-7 class review: fail CLOSED on every scan error, not just a missing library ---

@test "the pre-push hook fails CLOSED when the scanner itself errors (grep exits 2, not 0 or 1)" {
  install_test_team_hooks

  local fakebin; fakebin="$(mktemp -d)"
  printf '#!/bin/bash\nexit 2\n' > "$fakebin/grep"
  chmod +x "$fakebin/grep"

  echo "totally ordinary content" > "$TEAM/ordinary.txt"
  git -C "$TEAM" add ordinary.txt
  git -C "$TEAM" -c user.name=t -c user.email=t@t.com commit --no-verify -qm 'ordinary commit'
  PATH="$fakebin:$PATH" run git -C "$TEAM" push origin main
  [ "$status" -ne 0 ]
  run git -C "$BRAIN_ROOT/origin-team.git" show main:ordinary.txt
  [ "$status" -ne 0 ]
}

@test "the pre-push hook fails CLOSED when the range it is given is invalid (rev-list itself errors)" {
  install_test_team_hooks

  echo "totally ordinary content" > "$TEAM/ordinary.txt"
  git -C "$TEAM" add ordinary.txt
  git -C "$TEAM" -c user.name=t -c user.email=t@t.com commit --no-verify -qm 'ordinary commit'
  local local_sha; local_sha=$(git -C "$TEAM" rev-parse HEAD)
  local bogus_sha=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef   # well-formed, but no such object
  run bash -c "printf 'refs/heads/main %s refs/heads/main %s\n' '$local_sha' '$bogus_sha' | '$TEAM/.git/hooks/pre-push' origin origin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not enumerate objects"* ]] || false
}

@test "the pre-commit hook fails CLOSED when the scanner itself errors (grep exits 2, not 0 or 1)" {
  install_test_team_hooks

  local fakebin; fakebin="$(mktemp -d)"
  printf '#!/bin/bash\nexit 2\n' > "$fakebin/grep"
  chmod +x "$fakebin/grep"

  echo "totally ordinary content" > "$TEAM/ordinary.txt"
  git -C "$TEAM" add ordinary.txt
  PATH="$fakebin:$PATH" run git -C "$TEAM" commit -qm 'should be refused'
  [ "$status" -ne 0 ]
  run git -C "$TEAM" log --oneline
  [[ "$output" != *"should be refused"* ]] || false
}
