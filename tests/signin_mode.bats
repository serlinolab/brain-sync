#!/usr/bin/env bats
# Sign-in mode (MAX-2055): a Mac set up through the app's "Sign in with MediaBuy" reaches GitHub
# over HTTPS with the app's credential helper; a Mac without the mode keeps its SSH deploy keys.

setup() {
  T="$(mktemp -d)"; export HOME="$T/home"; mkdir -p "$HOME"
  STATE="$T/state"; mkdir -p "$STATE"; export STATE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export GIT_CONFIG_NOSYSTEM=1
  # A person's own helper that must never answer for the Brain.
  git config --global credential.helper '!f(){ echo username=someone-else; echo password=WRONG; }; f'
  # The app's helper: records how it was asked and answers like SerlinoLabBrain --git-credential.
  APP="$T/Serlino Brain.app/Contents/MacOS/SerlinoLabBrain"; mkdir -p "$(dirname "$APP")"
  printf '#!/bin/bash\necho "$*" >> "%s/helper-calls"\ncat > /dev/null\necho username=x-access-token\necho password=ghs_from_the_app\n' "$T" > "$APP"
  chmod +x "$APP"
}
teardown() { rm -rf "$T"; }

load_mode() { bash -c "STATE='$STATE'; source '$REPO_ROOT/lib/auth_mode.sh'; $1"; }

@test "without auth-mode a Mac keeps the SSH defaults and git config is untouched" {
  run load_mode 'echo "${EXPECTED_TEAM_REMOTE:-unset} ${GIT_CONFIG_COUNT:-unset} ${BRAIN_SIGNIN_MODE:-0}"'
  [ "$output" = "unset unset 0" ]
  run bash -c "STATE='$STATE'; source '$REPO_ROOT/lib/auth_mode.sh'; source '$REPO_ROOT/lib/common.sh' 2>/dev/null; echo \"\$EXPECTED_TEAM_REMOTE \$EXPECTED_MIRROR_REMOTE\""
  [ "$output" = "git@brain-team:serlinolab/brain-team.git git@brain-mirror:serlinolab/Serlinolab-Brain.git" ]
}

@test "in sign-in mode the remotes are HTTPS and only the app's helper answers for github.com" {
  echo signin > "$STATE/auth-mode"; echo "$APP" > "$STATE/credential-helper"
  run load_mode 'echo "$EXPECTED_TEAM_REMOTE $EXPECTED_MIRROR_REMOTE $ONLINE_CHECK_REMOTE $GIT_TERMINAL_PROMPT"'
  [ "$output" = "https://github.com/serlinolab/brain-team.git https://github.com/serlinolab/Serlinolab-Brain.git https://github.com/serlinolab/Serlinolab-Brain.git 0" ]
  run load_mode 'printf "protocol=https\nhost=github.com\npath=serlinolab/brain-team.git\n\n" | git credential fill'
  [ "$status" -eq 0 ]
  [[ "$output" == *"password=ghs_from_the_app"* ]]
  [[ "$output" != *WRONG* ]]
  grep -qx -- "--git-credential get" "$T/helper-calls"
  # Another host is not the app's business: the person's own helper still answers there.
  run load_mode 'printf "protocol=https\nhost=example.com\n\n" | git credential fill'
  [[ "$output" == *"password=WRONG"* ]]
}

@test "sign-in mode appends to a caller's own GIT_CONFIG entries instead of replacing them" {
  echo signin > "$STATE/auth-mode"; echo "$APP" > "$STATE/credential-helper"
  run bash -c "export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.defaultBranch GIT_CONFIG_VALUE_0=main; STATE='$STATE'; source '$REPO_ROOT/lib/auth_mode.sh'; echo \"\$GIT_CONFIG_COUNT \$(git config init.defaultBranch)\""
  [ "$output" = "3 main" ]
}

@test "a missing helper leaves git without a password prompt instead of hanging" {
  echo signin > "$STATE/auth-mode"; echo "$T/nowhere" > "$STATE/credential-helper"
  run load_mode 'echo "${GIT_CONFIG_COUNT:-unset} $GIT_TERMINAL_PROMPT"'
  [ "$output" = "unset 0" ]
}
