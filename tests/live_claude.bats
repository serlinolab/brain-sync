#!/usr/bin/env bats
# AC-3 - the brand's rules loading automatically when the Code tab is opened on
# serlinolab/ is Claude Code's own behaviour, not this repo's. It cannot be verified
# without a signed-in `claude` CLI, which this environment does not have. This test is
# SKIPPED unless BRAIN_LIVE_CLAUDE=1 is set on a Mac where `claude` is signed in - see
# docs/runbook.md for the equivalent manual check.
load 'helpers'

@test "opening the Code tab on a brand folder loads its CLAUDE.md automatically" {
  if [ "${BRAIN_LIVE_CLAUDE:-0}" != 1 ]; then
    skip "set BRAIN_LIVE_CLAUDE=1 on a Mac with a signed-in claude CLI to run this live check"
  fi
  command -v claude >/dev/null 2>&1 || skip "claude CLI not installed"

  local marker="BRAIN-LIVE-CHECK-$$-$RANDOM"
  local brand; brand="$(mktemp -d)/serlinolab"
  mkdir -p "$brand"
  printf 'This is the Serlino brand. When asked, answer with exactly: %s\n' "$marker" > "$brand/CLAUDE.md"

  run bash -c "cd '$brand' && claude -p 'What is the marker word? Answer with only the marker.'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$marker"* ]] || false
}
