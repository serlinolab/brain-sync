#!/usr/bin/env bats
# AC-9 - the creator-facing part of README.md uses no git vocabulary. The "For Max" section
# at the end is allowed to (it links to docs/runbook.md, which is full of it).
load 'helpers'

@test "the creator-facing section of README.md contains no git vocabulary" {
  local creator_section
  creator_section=$(sed -n '1,/^## For Max$/p' "$REPO_ROOT/README.md" | sed '$d')
  run grep -inE '\b(git|repo|repository|commit|push|pull|branch|clone|merge|PR|key|SSH)\b' <<<"$creator_section"
  [ "$status" -ne 0 ]
}

@test "README.md has a For Max section pointing at docs/runbook.md" {
  grep -q '^## For Max$' "$REPO_ROOT/README.md"
  run sed -n '/^## For Max$/,$p' "$REPO_ROOT/README.md"
  [[ "$output" == *"docs/runbook.md"* ]] || false
}

# MAX-1515 change A: setup finishes itself in the background (lib/complete_setup.sh, run from
# every sync cycle) once Max has registered the deploy key - the creator pastes the setup line
# exactly once, ever, and never has to come back to Terminal a second time.
@test "the creator-facing section sends Max the line once and never asks for a second run" {
  local creator_section
  creator_section=$(sed -n '1,/^## For Max$/p' "$REPO_ROOT/README.md" | sed '$d')
  run grep -qF "Send Max the line starting SERLINO-BRAIN-SETUP" <<<"$creator_section"
  [ "$status" -eq 0 ]
  run grep -qi 'second time\|second run\|paste.*again\|run it again\|run the.*line again' <<<"$creator_section"
  [ "$status" -ne 0 ]
}

# The brain's skills read their data through the MediaBuy connector; setup cannot add it,
# because the sign-in must be the person's own.
@test "the creator-facing section explains how to connect MediaBuy" {
  local creator_section
  creator_section=$(sed -n '1,/^## For Max$/p' "$REPO_ROOT/README.md" | sed '$d')
  run grep -qF "https://mcp-mediabuy.maxora.it/mcp" <<<"$creator_section"
  [ "$status" -eq 0 ]
  run grep -qF "Settings → Connectors" <<<"$creator_section"
  [ "$status" -eq 0 ]
}

@test "the runbook covers the MediaBuy user when provisioning and when revoking" {
  run grep -qi "MediaBuy user" "$REPO_ROOT/docs/runbook.md"
  [ "$status" -eq 0 ]
  run grep -qF "is_active = false" "$REPO_ROOT/docs/runbook.md"
  [ "$status" -eq 0 ]
}
