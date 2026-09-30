#!/usr/bin/env bats
# Fresh Mac without Apple's Command Line Tools (CLT): /usr/bin/git is a stub until CLT is
# installed, and calling it pops the "install developer tools?" dialog and fails. setup.sh's
# and lib/common.sh's xcode_clt_ready() gate every git-touching step on `xcode-select -p`
# succeeding first (see the "IDENTICAL COPY" comment in both files for why it's duplicated).
#
# The tools-missing path exits before touching git at all, so these tests never need the full
# engine/mirror/team fixture tests/setup.bats builds - there is nothing left for it to reach.
load 'helpers'

setup() {
  brain_test_setup
  mkdir -p "$HOME/bin"
}
teardown() { brain_test_teardown; }

# A canary, not a working git: proves whether git was ever invoked, without doing real work
# or touching the network - exactly what "never trigger the installer" needs to be provable.
stub_git_canary() {
  GIT_CALL_LOG="$HOME/git-calls.log"; export GIT_CALL_LOG
  : > "$GIT_CALL_LOG"
  cat > "$HOME/bin/git" <<'EOF'
#!/bin/bash
# `git --version` answers like a real git, so a tools-present run gets PAST the check; every
# other call is logged and fails, which is all these tests need to see git was reached.
[ "${1:-}" = "--version" ] && { echo "git version 2.39.0"; exit 0; }
echo "$*" >> "$GIT_CALL_LOG"
exit 1
EOF
  chmod +x "$HOME/bin/git"
}

stub_clt_missing() {
  INSTALL_CALL_LOG="$HOME/install-calls.log"; export INSTALL_CALL_LOG
  : > "$INSTALL_CALL_LOG"
  cat > "$HOME/bin/xcode-select" <<'EOF'
#!/bin/bash
case "${1:-}" in
  -p) echo "xcode-select: error: unable to get active developer directory" >&2; exit 2 ;;
  --install) echo installed >> "$INSTALL_CALL_LOG" ;;
esac
EOF
  chmod +x "$HOME/bin/xcode-select"
  export PATH="$HOME/bin:$PATH"
}

stub_clt_present() {
  mkdir -p "$HOME/clt-dir"
  cat > "$HOME/bin/xcode-select" <<EOF
#!/bin/bash
case "\${1:-}" in
  -p) echo "$HOME/clt-dir" ;;
esac
EOF
  chmod +x "$HOME/bin/xcode-select"
  export PATH="$HOME/bin:$PATH"
}

@test "setup: tools missing starts the install once, prints the plain-language message, exits a distinct code, and touches nothing else" {
  stub_clt_missing
  stub_git_canary
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ "$status" -ne 1 ]
  [[ "$output" == *"Apple"* ]] || false
  [[ "$output" == *"developer tools"* ]] || false
  [[ "$output" == *"Install"* ]] || false
  [ "$(cat "$INSTALL_CALL_LOG")" = "installed" ]
  [ ! -s "$GIT_CALL_LOG" ]
  [ ! -e "$HOME/Serlinolab/.state/engine" ]
}

@test "setup: a cancelled install is started again on the next run, never stuck" {
  stub_clt_missing
  stub_git_canary
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"click Install"* ]] || false
  [[ "$output" == *"developer.apple.com/download/all"* ]] || false
  [ "$(wc -l < "$INSTALL_CALL_LOG")" -eq 2 ]
  [ ! -s "$GIT_CALL_LOG" ]
}

@test "setup: tools present proceeds past the check" {
  stub_clt_present
  stub_git_canary
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  grep -q . "$GIT_CALL_LOG"
}

@test "sync cycle: tools missing skips the cycle, logs once, and never calls xcode-select --install" {
  stub_clt_missing
  stub_git_canary
  run run_sync_cycle
  [ "$status" -eq 0 ]
  [ ! -s "$INSTALL_CALL_LOG" ]
  [ ! -s "$GIT_CALL_LOG" ]
  [ "$(grep -ci "developer tools" "$LOG")" -eq 1 ]
}

@test "sync cycle: tools present is unaffected by the check" {
  stub_clt_present
  stub_git_canary
  run run_sync_cycle
  grep -q . "$GIT_CALL_LOG"
}

@test "launchd self-update launcher: tools missing skips before any git and never starts the install" {
  stub_clt_missing
  stub_git_canary
  mkdir -p "$HOME/Serlinolab/.state"
  BRAIN_ROOT="$HOME/Serlinolab" run bash "$REPO_ROOT/lib/launcher.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$GIT_CALL_LOG" ]
  [ ! -s "$INSTALL_CALL_LOG" ]
  grep -qi "developer tools" "$HOME/Serlinolab/.state/sync.log"
}
