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

# Review fix 7: setup does not finish itself on the first run - part of it waits on Max. The
# creator pastes the line once, sends Max what it prints, and pastes the SAME line again once
# Max confirms he is done, to pick up where the first run left off.
@test "the creator-facing section says to run the setup line a second time once Max confirms" {
  local creator_section
  creator_section=$(sed -n '1,/^## For Max$/p' "$REPO_ROOT/README.md" | sed '$d')
  run grep -qi 'again' <<<"$creator_section"
  [ "$status" -eq 0 ]
  run grep -qi 'second run\|paste.*again\|run it again\|run the.*line again' <<<"$creator_section"
  [ "$status" -eq 0 ]
}
