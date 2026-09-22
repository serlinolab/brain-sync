#!/usr/bin/env bats
# AC-4 - nothing in team/ can contribute instructions to a Claude session, whether it
# arrived from a colleague's push or was typed directly on this Mac. MAX-1515 (amended):
# serlinolab/ moved beside team/, not nested inside it, so the ONE remaining layer is the
# static, non-cone sparse-checkout on the team clone (lib/team_layout.sh) - there is no
# runtime quarantine sweep to fall back on, so this file leans on real sync cycles.
load 'helpers'
setup() {
  brain_test_setup
  make_fake_team_repo
  configure_team_sparse_checkout
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git"; export ONLINE_CHECK_REMOTE
}
teardown() { brain_test_teardown; }

@test "a colleague's CLAUDE.md, AGENTS.md, CLAUDE.local.md, a .claude symlink, and a nested .claude never land on disk after a real sync cycle, while ordinary notes arrive" {
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  mkdir -p "$other/payload/rules" "$other/notes/.claude/skills/y"
  echo x > "$other/CLAUDE.md"
  echo x > "$other/AGENTS.md"
  echo x > "$other/CLAUDE.local.md"
  echo x > "$other/payload/rules/x.md"
  ln -s payload "$other/.claude"
  echo x > "$other/notes/.claude/skills/y/SKILL.md"
  echo x > "$other/notes/idea.md"
  git -C "$other" add -A; git_commit "$other" 'colleague notes'
  git -C "$other" push -q origin main
  rm -rf "$other"

  run_sync_cycle

  [ ! -e "$TEAM/CLAUDE.md" ]
  [ ! -e "$TEAM/AGENTS.md" ]
  [ ! -e "$TEAM/CLAUDE.local.md" ]
  [ ! -e "$TEAM/.claude" ]
  [ ! -e "$TEAM/notes/.claude" ]
  # an ordinary file in team/ is data, not instructions - it arrives even though it sat
  # beside an excluded name
  [ "$(cat "$TEAM/payload/rules/x.md")" = x ]
  [ "$(cat "$TEAM/notes/idea.md")" = x ]
}

@test "a file with spaces in its name syncs correctly" {
  echo hi > "$TEAM/a file with spaces.txt"
  run_sync_cycle
  [ "$(git -C "$TEAM" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)" -eq 0 ]   # pushed
  git -C "$BRAIN_ROOT/origin-team.git" show main:"a file with spaces.txt" >/dev/null
}

@test "sparse-checkout check-rules excludes .claude regardless of git's guess at its object type" {
  # This is the exact reproduction from the review: `check-rules --no-cone` treats
  # `!.claude/` (trailing-slash-only) as a directory-only exclusion, so a path git cannot yet
  # see as a directory (nothing has been checked out there yet - the state check-rules itself
  # is evaluated in) is reported INCLUDED. Querying inside a fresh $TEAM (nothing checked out
  # under that name yet) reproduces exactly that ambiguity.
  run bash -c "printf '.claude\n' | git -C '$TEAM' sparse-checkout check-rules --no-cone"
  [ -z "$output" ]
}
