#!/usr/bin/env bats
# Max's other Mac, 2026-10-03: a cycle sat in `git fetch` over ssh for 51 minutes. ConnectTimeout
# only bounds OPENING a connection; one that dies afterwards (laptop asleep mid-transfer, network
# change, "Connection reset by peer") waited forever, and launchd never starts a new run while
# the old one is alive - so the Mac stopped syncing until someone killed ssh by hand. The menu-bar
# app turned it red, which is how it was found. Both network paths now give up on a dead link.
load 'helpers'
setup() { brain_test_setup; }
teardown() { brain_test_teardown; }

@test "the engine's ssh gives up on a connection that stops answering (~1 minute)" {
  # What ssh actually resolves from the engine's own options, not a string match.
  run bash -c "source '$REPO_ROOT/lib/common.sh'; eval \"set -- \$GIT_SSH_COMMAND\"; shift; ssh -G \"\$@\" github.com"
  [ "$status" -eq 0 ]
  [[ "$output" == *"serveraliveinterval 15"* ]] || false
  [[ "$output" == *"serveralivecountmax 4"* ]] || false
  [[ "$output" == *"connecttimeout 15"* ]] || false
  [[ "$output" == *"batchmode yes"* ]] || false
}

@test "the self-update's https git gives up on a transfer that stalls" {
  make_fake_brain_sync_origin
  local bin="$BRAIN_ROOT/bin"; mkdir -p "$bin"
  printf '%s\n' '#!/bin/bash' \
    'echo "limit=${GIT_HTTP_LOW_SPEED_LIMIT:-unset} time=${GIT_HTTP_LOW_SPEED_TIME:-unset}" >> "$BRAIN_ROOT/git-env.log"' \
    "exec $(command -v git) \"\$@\"" > "$bin/git"
  chmod +x "$bin/git"
  PATH="$bin:$PATH" BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" bash "$REPO_ROOT/lib/launcher.sh" --selfcheck-only
  rm -rf "$BRAIN_SYNC_WORK"
  [ -s "$BRAIN_ROOT/git-env.log" ]
  if grep -q "unset" "$BRAIN_ROOT/git-env.log"; then false; fi
  grep -q "limit=1000 time=60" "$BRAIN_ROOT/git-env.log"
}
