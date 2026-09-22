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
  [[ "$output" == *"looks like it contains a secret"* ]]
  run git -C "$TEAM" log --oneline
  [[ "$output" != *oops* ]]
}

@test "the pre-commit hook scans the STAGED blob, not the working-tree copy that was later overwritten" {
  install_test_team_hooks

  fake_github_pat > "$TEAM/secret.txt"
  git -C "$TEAM" add secret.txt
  echo "harmless, edited after staging" > "$TEAM/secret.txt"   # working tree no longer looks like a secret
  run git -C "$TEAM" commit -qm 'still carries the staged secret'
  [ "$status" -ne 0 ]
  [[ "$output" == *"looks like it contains a secret"* ]]
}

@test "the pre-commit hook fails CLOSED when the secret-scan library cannot be loaded" {
  install_test_team_hooks "$BRAIN_ROOT/no-such-libdir"   # points the hook at a library that isn't there

  echo "totally ordinary content" > "$TEAM/ordinary.txt"
  git -C "$TEAM" add ordinary.txt
  run git -C "$TEAM" commit -qm 'should be refused'
  [ "$status" -ne 0 ]
  run git -C "$TEAM" log --oneline
  [[ "$output" != *"should be refused"* ]]
}

@test "the pre-push hook refuses a push that carries a secret even if it slipped past pre-commit" {
  install_test_team_hooks

  fake_github_pat > "$TEAM/secret.txt"
  git -C "$TEAM" add secret.txt
  git -C "$TEAM" -c user.name=t -c user.email=t@t.com commit --no-verify -qm 'bypassed pre-commit intentionally for this test'

  run git -C "$TEAM" push origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *"looks like it contains a secret"* ]]
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
  [[ "$output" == *"looks like it contains a secret"* ]]
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
  [[ "$output" == *"looks like it contains a secret"* ]]
}
