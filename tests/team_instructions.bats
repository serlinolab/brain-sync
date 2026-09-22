#!/usr/bin/env bats
# AC-4 - nothing in team/ can contribute instructions to a Claude session, whether it
# arrived from a colleague's push or was typed directly on this Mac.
load 'helpers'
setup() {
  brain_test_setup
  make_fake_team_repo
  configure_team_sparse_checkout
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git"; export ONLINE_CHECK_REMOTE
}
teardown() { brain_test_teardown; }

@test "instruction files a colleague pushed never check out, ordinary files do, and a colleague's serlinolab/ never collides with the mirror" {
  make_fake_mirror   # a real, independently-cloned mirror sits at $TEAM/serlinolab already
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  mkdir -p "$other/.claude/skills/x" "$other/.claude/rules" "$other/notes/.claude/skills/y" "$other/serlinolab"
  echo x > "$other/CLAUDE.md"
  echo x > "$other/AGENTS.md"
  echo x > "$other/CLAUDE.local.md"
  echo x > "$other/.claude/skills/x/SKILL.md"
  echo x > "$other/.claude/rules/x.md"
  echo x > "$other/notes/CLAUDE.md"
  echo x > "$other/notes/.claude/skills/y/SKILL.md"
  echo x > "$other/notes/idea.md"
  echo x > "$other/serlinolab/x.md"
  git -C "$other" add -A; git_commit "$other" 'colleague notes'
  git -C "$other" push -q origin main
  rm -rf "$other"

  run_sync_cycle

  [ ! -e "$TEAM/CLAUDE.md" ]
  [ ! -e "$TEAM/AGENTS.md" ]
  [ ! -e "$TEAM/CLAUDE.local.md" ]
  [ ! -e "$TEAM/.claude" ]
  [ ! -e "$TEAM/notes/CLAUDE.md" ]
  [ ! -e "$TEAM/notes/.claude" ]
  [ "$(cat "$TEAM/notes/idea.md")" = x ]
  # the colleague's serlinolab/x.md never checks out and never lands where the real,
  # independently-cloned mirror lives
  [ ! -e "$TEAM/serlinolab/x.md" ]
  [ "$(cat "$MIRROR/sub/file.txt")" = hello ]   # the real mirror's own content is untouched
}

@test "a locally-created instruction file is quarantined before it is ever staged, and never deleted" {
  mkdir -p "$TEAM/.claude/skills/x" "$TEAM/notes"
  echo local > "$TEAM/CLAUDE.md"
  echo local > "$TEAM/notes/idea.md"
  echo local > "$TEAM/.claude/skills/x/SKILL.md"

  run_sync_cycle

  [ ! -e "$TEAM/CLAUDE.md" ]
  [ ! -e "$TEAM/.claude" ]
  [ -f "$TEAM/notes/idea.md" ]   # an ordinary file right next to it is untouched
  local found; found=$(find "$QUARANTINE" -name CLAUDE.md 2>/dev/null | head -1)
  [ -n "$found" ]
  [ "$(cat "$found")" = local ]
  local found_claude_dir; found_claude_dir=$(find "$QUARANTINE" -type d -name skills 2>/dev/null | head -1)
  [ -n "$found_claude_dir" ]
  grep -q "quarantined instruction file: CLAUDE.md" "$LOG"
  # never staged, let alone pushed - the team repo never even saw a commit for it
  run git -C "$TEAM" log --all --oneline -- CLAUDE.md
  [ -z "$output" ]
}

@test "the nested mirror is never staged as a gitlink" {
  make_fake_mirror
  make_local_ahead_change
  run_sync_cycle
  run bash -c "git -C '$TEAM' ls-files -s | grep 160000"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "a file with spaces in its name syncs correctly" {
  echo hi > "$TEAM/a file with spaces.txt"
  run_sync_cycle
  [ "$(git -C "$TEAM" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)" -eq 0 ]   # pushed
  git -C "$BRAIN_ROOT/origin-team.git" show main:"a file with spaces.txt" >/dev/null
}

@test "the mirror carries a settings.local.json excluding only the team root's instruction files" {
  make_fake_mirror
  [ -f "$MIRROR/.claude/settings.local.json" ]
  python3 -m json.tool "$MIRROR/.claude/settings.local.json" >/dev/null
  local excludes; excludes=$(python3 -c "import json; print('\n'.join(json.load(open('$MIRROR/.claude/settings.local.json'))['claudeMdExcludes']))")
  [[ "$excludes" == *"$TEAM/CLAUDE.md"* ]]
  [[ "$excludes" == *"$TEAM/CLAUDE.local.md"* ]]
  [[ "$excludes" == *"$TEAM/AGENTS.md"* ]]
  [[ "$excludes" != *"$MIRROR/CLAUDE.md"* ]]   # never excludes the brand's own CLAUDE.md
}

@test "an mirror that already tracks settings.local.json is never overwritten" {
  make_fake_mirror
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-mirror.git" "$other"
  mkdir -p "$other/.claude"
  echo '{"claudeMdExcludes": ["theirs"]}' > "$other/.claude/settings.local.json"
  git -C "$other" add -A; git_commit "$other" 'ship our own settings'
  git -C "$other" push -q origin main
  rm -rf "$other"
  run_sync_cycle
  [ "$(cat "$MIRROR/.claude/settings.local.json")" = '{"claudeMdExcludes": ["theirs"]}' ]
  grep -q "not overwriting" "$LOG"
}
