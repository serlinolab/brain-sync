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

# Case 10 (2026-09-25): the creator-facing section explains, in plain language and still with
# no git vocabulary, that a text note is combined automatically and only a non-text file can
# still need Max.
@test "the creator-facing section explains that text notes combine automatically and only a non-text file needs Max" {
  local creator_section
  creator_section=$(sed -n '1,/^## For Max$/p' "$REPO_ROOT/README.md" | sed '$d')
  run grep -qi "kept automatically" <<<"$creator_section"
  [ "$status" -eq 0 ]
  run grep -qi "isn't plain text\|not plain text\|non-text" <<<"$creator_section"
  [ "$status" -eq 0 ]
}

@test "the runbook covers the manual fallback for a parked (binary) conflict" {
  run grep -qi "conflict_attempts" "$REPO_ROOT/docs/runbook.md"
  [ "$status" -eq 0 ]
  run grep -qi "binary" "$REPO_ROOT/docs/runbook.md"
  [ "$status" -eq 0 ]
}

# The "Serlino Brain" launcher (lib/brain_launcher.sh): where it is, what happens, and the
# "Trust workspace" click Claude asks for every time - without it the Brain's rules stay off.
@test "the creator-facing section explains opening the Brain and the trust click" {
  local creator_section
  creator_section=$(sed -n '1,/^## For Max$/p' "$REPO_ROOT/README.md" | sed '$d')
  run grep -q '^## Opening the Brain$' <<<"$creator_section"
  [ "$status" -eq 0 ]
  run grep -qF 'Double-click **Serlino Brain** on your Desktop' <<<"$creator_section"
  [ "$status" -eq 0 ]
  run grep -qi 'drag it to the Dock' <<<"$creator_section"
  [ "$status" -eq 0 ]
  run grep -qF '"get started"' <<<"$creator_section"
  [ "$status" -eq 0 ]
  run grep -qF 'Trust workspace' <<<"$creator_section"
  [ "$status" -eq 0 ]  # Where it is when the Desktop shortcut never arrived (macOS may refuse that one write).
  run grep -qF 'Applications folder inside your home' <<<"$creator_section"
  [ "$status" -eq 0 ]
  # "after setup" used to promise no approvals at all, while the trust click is every time.
  run grep -qi 'approve anything after setup' <<<"$creator_section"
  [ "$status" -ne 0 ]
}

@test "the runbook says how to rebuild the launcher" {
  run grep -qF 'Serlino Brain.app' "$REPO_ROOT/docs/runbook.md"
  [ "$status" -eq 0 ]
}
