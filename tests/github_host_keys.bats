#!/usr/bin/env bats
# Oscar's brand-new Mac (2026-09-30): every SSH call failed "Host key verification failed"
# because BatchMode refuses an unknown host and the Mac had never met github.com. The engine
# now ships GitHub's published host keys and checks them strictly (no trust-on-first-use).
load 'helpers'
setup() { brain_test_setup; }
teardown() { brain_test_teardown; }

@test "GIT_SSH_COMMAND checks github.com strictly against the shipped host keys" {
  run bash -c "source '$REPO_ROOT/lib/common.sh'; printf '%s' \"\$GIT_SSH_COMMAND\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"StrictHostKeyChecking=yes"* ]] || false
  [[ "$output" == *"UserKnownHostsFile=\"$REPO_ROOT/lib/github_known_hosts\""* ]] || false
}

@test "the shipped host keys are GitHub's published fingerprints" {
  run ssh-keygen -lf "$REPO_ROOT/lib/github_known_hosts"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU github.com (ED25519)"* ]] || false
  [[ "$output" == *"SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM github.com (ECDSA)"* ]] || false
  [[ "$output" == *"SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s github.com (RSA)"* ]] || false
}
