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

@test "sparse-checkout check-rules excludes .claude and serlinolab regardless of git's guess at their object type" {
  # This is the exact reproduction from the review: `check-rules --no-cone` treats
  # `!.claude/` and `!/serlinolab/` (trailing-slash-only) as directory-only exclusions, so a
  # path git cannot yet see as a directory (nothing has been checked out there yet - the
  # state check-rules itself is evaluated in) is reported INCLUDED. Querying inside a fresh
  # $TEAM (nothing checked out under those names yet) reproduces exactly that ambiguity.
  run bash -c "printf '.claude\nserlinolab\n' | git -C '$TEAM' sparse-checkout check-rules --no-cone"
  [ -z "$output" ]
}

@test "a colleague's .claude committed as a symlink (not a directory) is still excluded, and its ordinary target folder still checks out" {
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  mkdir -p "$other/payload/rules"
  echo x > "$other/payload/rules/override.md"
  ln -s payload "$other/.claude"
  git -C "$other" add -A; git_commit "$other" 'symlinked .claude'
  git -C "$other" push -q origin main
  rm -rf "$other"

  run_sync_cycle

  [ ! -e "$TEAM/.claude" ]
  [ -f "$TEAM/payload/rules/override.md" ]
}

@test "a colleague's file named serlinolab at the team root never checks out and never collides with the mirror slot" {
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  echo x > "$other/serlinolab"
  git -C "$other" add -A; git_commit "$other" 'file named serlinolab'
  git -C "$other" push -q origin main
  rm -rf "$other"

  run_sync_cycle

  [ ! -e "$TEAM/serlinolab" ]
}

@test "case-insensitive instruction names and a symlink escaping into the mirror are both neutralized" {
  make_fake_mirror
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  echo x > "$other/Claude.md"
  mkdir -p "$other/notes"
  echo x > "$other/notes/AGENTS.MD"
  ln -s ../serlinolab/sub/file.txt "$other/notes/link"
  git -C "$other" add -A; git_commit "$other" 'case variants + escaping symlink'
  git -C "$other" push -q origin main
  rm -rf "$other"

  run_sync_cycle

  [ ! -e "$TEAM/Claude.md" ]
  [ ! -e "$TEAM/notes/AGENTS.MD" ]
  [ ! -L "$TEAM/notes/link" ]
  [ "$(cat "$MIRROR/sub/file.txt")" = hello ]
}

@test "sync.sh calls quarantine_instructions again after sync_team, not only before it" {
  # Per the review: a rebase can occasionally materialise a path the sparse-checkout would
  # otherwise refuse to check out, and this Mac's own git could not be made to reproduce that
  # corner from outside in this environment (real end-to-end pushes of the excluded names
  # never materialize, verified above), so the orchestration itself is asserted directly
  # against the real file sync.sh runs: quarantine_instructions must appear a second time,
  # textually after the sync_team call, so nothing that arrives with the incoming update can
  # survive to the end of the cycle uncaught.
  local after_sync_team; after_sync_team=$(sed -n '/sync_team/,$p' "$REPO_ROOT/sync.sh")
  case "$after_sync_team" in
    *quarantine_instructions*) : ;;
    *) return 1 ;;
  esac
}


@test "an invalid team/serlinolab slot (a plain file where the mirror clone belongs) is quarantined, not adopted" {
  mkdir -p "$TEAM"
  echo 'not a clone' > "$MIRROR"
  run_sync_cycle
  [ ! -f "$MIRROR" ]
  found=$(find "$QUARANTINE" -name serlinolab 2>/dev/null | head -1)
  [ -n "$found" ]
  [ "$(cat "$found")" = 'not a clone' ]
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
