#!/usr/bin/env bats
# AC-7 - a file that looks like it holds a secret never reaches the remote, whether it goes
# through the engine's own commit_local or a human commit/push protected by the installed
# git hooks. Neither rejection wedges the rest of the cycle. Fake secrets are built by
# concatenation at runtime so this file itself never contains a real-looking token.
load 'helpers'
setup() { brain_test_setup; make_fake_team_repo; }
teardown() { brain_test_teardown; }

fake_github_pat() { printf 'ghp_%s\n' "$(printf 'a%.0s' $(seq 1 36))"; }

@test "the engine rejects a secret-shaped file, logs and marks it, and still syncs every other file" {
  fake_github_pat > "$TEAM/secret.txt"
  echo "safe content" > "$TEAM/safe.txt"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  grep -q "REJECT secret: secret.txt" "$LOG"
  grep -q "secret.txt" "$MARK"
  ! grep -qi 'password\|key' <<<"$(cat "$TEAM/secret.txt")"   # sanity: fixture still local, untouched
  git -C "$BRAIN_ROOT/origin-team.git" show main:safe.txt >/dev/null   # the other file made it
  run git -C "$BRAIN_ROOT/origin-team.git" show main:secret.txt
  [ "$status" -ne 0 ]   # the secret never reached the remote
}

@test "the pre-commit hook refuses a secret-shaped staged file directly" {
  configure_team_sparse_checkout   # not needed for the hook itself, but this is the real install path
  local libdir="$STATE/engine/lib"
  mkdir -p "$libdir" "$TEAM/.git/hooks"
  cp "$REPO_ROOT/lib/secretscan.sh" "$libdir/secretscan.sh"
  sed "s#__LIBDIR__#$libdir#" > "$TEAM/.git/hooks/pre-commit" <<'HOOK'
#!/bin/bash
set -u
source "__LIBDIR__/secretscan.sh" 2>/dev/null || exit 0
while IFS= read -r -d '' f; do
  if secret_scan_file "$f"; then
    printf 'refusing commit: %s looks like it contains a secret (a password or access key)\n' "$f" >&2
    exit 1
  fi
done < <(git diff --cached --name-only -z)
exit 0
HOOK
  chmod +x "$TEAM/.git/hooks/pre-commit"

  fake_github_pat > "$TEAM/secret.txt"
  git -C "$TEAM" add secret.txt
  run git -C "$TEAM" commit -qm 'oops'
  [ "$status" -ne 0 ]
  [[ "$output" == *"looks like it contains a secret"* ]]
  run git -C "$TEAM" log --oneline
  [[ "$output" != *oops* ]]
}

@test "the pre-push hook refuses a push that carries a secret even if it slipped past pre-commit" {
  local libdir="$STATE/engine/lib"
  mkdir -p "$libdir" "$TEAM/.git/hooks"
  cp "$REPO_ROOT/lib/secretscan.sh" "$libdir/secretscan.sh"
  sed "s#__LIBDIR__#$libdir#" > "$TEAM/.git/hooks/pre-push" <<'HOOK'
#!/bin/bash
set -u
source "__LIBDIR__/secretscan.sh" 2>/dev/null || exit 0
zero='0000000000000000000000000000000000000000'
while read -r local_ref local_sha remote_ref remote_sha; do
  [ "$local_sha" = "$zero" ] && continue
  while IFS= read -r -d '' f; do
    tmp=$(mktemp)
    git show "$local_sha:$f" > "$tmp" 2>/dev/null
    if secret_scan_file "$tmp"; then
      rm -f "$tmp"
      printf 'refusing push: %s looks like it contains a secret (a password or access key)\n' "$f" >&2
      exit 1
    fi
    rm -f "$tmp"
  done < <(git ls-tree -r --name-only -z "$local_sha")
done
exit 0
HOOK
  chmod +x "$TEAM/.git/hooks/pre-push"

  fake_github_pat > "$TEAM/secret.txt"
  git -C "$TEAM" add secret.txt
  git -C "$TEAM" -c user.name=t -c user.email=t@t.com commit -qm 'bypassed pre-commit intentionally for this test'

  run git -C "$TEAM" push origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *"looks like it contains a secret"* ]]
  run git -C "$BRAIN_ROOT/origin-team.git" show main:secret.txt
  [ "$status" -ne 0 ]
}
