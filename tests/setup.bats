#!/usr/bin/env bats
load 'helpers'

setup_setup_test() {
  BRAIN_ROOT="$(mktemp -d)"; export BRAIN_ROOT
  HOME="$(mktemp -d)"; export HOME
  mkdir -p "$HOME/bin" "$BRAIN_ROOT/repos"
  REAL_GIT="$(type -P git)"; export REAL_GIT
  git init -q --bare "$BRAIN_ROOT/repos/engine.git"
  git init -q --bare "$BRAIN_ROOT/repos/mirror.git"
  git init -q --bare "$BRAIN_ROOT/repos/personal.git"
  local work; work="$(mktemp -d)"
  git init -q -b main "$work"
  mkdir -p "$work/lib"
  cp "$REPO_ROOT/lib/launcher.sh" "$work/lib/launcher.sh"
  git -C "$work" add -A; git -C "$work" -c user.name=fixture -c user.email=fixture@example.com commit -qm engine
  git -C "$work" remote add origin "$BRAIN_ROOT/repos/engine.git"; git -C "$work" push -q origin main
  rm -rf "$work"
  printf '%s\n' '#!/bin/bash' \
    'args=("$@")' \
    'for i in "${!args[@]}"; do' \
    '  case "${args[$i]}" in' \
    '    git@brain-mirror:serlinolab/Serlinolab-Brain.git) args[$i]="$BRAIN_ROOT/repos/mirror.git" ;;' \
    '    git@brain-personal:serlinolab/brain-personal-*.git) args[$i]="$BRAIN_ROOT/repos/personal.git" ;;' \
    '  esac' \
    'done' \
    'if [ "${FAIL_MIRROR:-0}" = 1 ] && [[ " $* " == *" git@brain-mirror:serlinolab/Serlinolab-Brain.git "* ]]; then exit 1; fi' \
    'exec "$REAL_GIT" "${args[@]}"' > "$HOME/bin/git"
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

@test "setup refuses unrelated existing mirror and personal repositories" {
  mkdir -p "$HOME/Serlino/personal"
  git init -q "$HOME/Serlino/serlinolab"
  git -C "$HOME/Serlino/serlinolab" remote add origin https://unrelated.example/mirror.git
  git init -q "$HOME/Serlino/personal/shared"
  git -C "$HOME/Serlino/personal/shared" remote add origin https://unrelated.example/personal.git
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HOME/Serlino/serlinolab"*"unrelated.example/mirror.git"* ]]
  [[ "$output" == *"$HOME/Serlino/personal/shared"*"unrelated.example/personal.git"* ]]
}

@test "setup records person once and refuses a later different person" {
  BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -eq 0 ]
  BRAIN_PERSON=bob run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/Serlino/.state/person")" = alice ]
  [[ "$output" == *"found 'alice', requested 'bob'"* ]]
}

@test "failed setup never writes the completion marker" {
  FAIL_MIRROR=1 BRAIN_PERSON=alice run bash "$REPO_ROOT/setup.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/Serlino/.state/setup-complete" ]
}
