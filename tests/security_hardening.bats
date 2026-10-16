#!/usr/bin/env bats
load 'helpers'
setup() { brain_test_setup; }
teardown() { brain_test_teardown; }

@test "mirror sanitize failure leaves team commits, pulls and pushes working" {
  make_fake_team_repo
  seed_repo "$EXPECTED_MIRROR_REMOTE" "$MIRROR" sub/file.txt
  local other="$ROOT/writer" real_find
  git clone -q "$EXPECTED_TEAM_REMOTE" "$other"
  echo incoming > "$other/incoming.txt"
  git -C "$other" add incoming.txt; git_commit "$other" incoming
  git -C "$other" push -q origin main
  echo outgoing > "$TEAM/outgoing.txt"
  # Force complete_setup, then fail its mirror sanitizer's directory scan.
  git -C "$MIRROR" config core.symlinks false
  real_find=$(command -v find)
  mkdir "$ROOT/bin"
  printf '#!/bin/bash\n[ "${1##*/}" != Serlinolab_Brain ] || exit 1\nexec "%s" "$@"\n' "$real_find" > "$ROOT/bin/find"
  chmod +x "$ROOT/bin/find"
  PATH="$ROOT/bin:$PATH" ONLINE_CHECK_REMOTE="$EXPECTED_MIRROR_REMOTE" run run_sync_cycle
  [ "$status" -eq 1 ]  # mirror failure is still reported
  [[ "$output" == *"Mirror configuration pending"* ]] || false
  [ "$(cat "$TEAM/incoming.txt")" = incoming ]
  [ "$(git -C "$EXPECTED_TEAM_REMOTE" show main:outgoing.txt)" = outgoing ]
  ! grep -q 'team folder configuration failed' "$LOG" || false
}

@test "an interrupted generated write leaves its temporary file outside staging" {
  source "$REPO_ROOT/lib/generated_files.sh"
  git init -q -b main "$MIRROR"
  printf 'previous\n' > "$MIRROR/generated.txt"
  git -C "$MIRROR" add -A; git_commit "$MIRROR" baseline
  # Kill a dedicated writer after mktemp, while its producer is running.
  run bash -c '
    source "$1/lib/generated_files.sh"
    interrupted_content() { printf "partial\n"; kill -KILL "$$"; }
    write_generated_file "$2/generated.txt" interrupted_content
  ' _ "$REPO_ROOT" "$MIRROR"
  [ "$status" -ne 0 ]
  [ -n "$(find "$MIRROR/.git" -name '.brain-sync.*' -print)" ]
  [ "$(cat "$MIRROR/generated.txt")" = previous ]
  git -C "$MIRROR" add -A
  [ -z "$(git -C "$MIRROR" diff --cached --name-only)" ]
}

@test "generated rename replaces a destination changed to a directory symlink" {
  source "$REPO_ROOT/lib/generated_files.sh"
  git init -q -b main "$MIRROR"
  mkdir -p "$PERSONAL"
  swap_destination() {
    ln -s "$PERSONAL" "$MIRROR/generated.txt"
    printf 'generated\n'
  }
  write_generated_file "$MIRROR/generated.txt" swap_destination
  [ ! -L "$MIRROR/generated.txt" ]
  [ "$(cat "$MIRROR/generated.txt")" = generated ]
  [ -z "$(ls -A "$PERSONAL")" ]
}

signpost_sentinel() {
  mkdir -p "$PERSONAL/ideas"
  printf 'private plan\000with bytes\n' > "$PERSONAL/ideas/plan.txt"
  cp "$PERSONAL/ideas/plan.txt" "$ROOT/sentinel.expected"
}

seed_mirror_links() {
  local repo="$1"
  mkdir -p "$repo/.agents" "$repo/.claude/skills/x" "$repo/nested"
  echo skill > "$repo/.claude/skills/x/SKILL.md"
  ln -s ../.claude/skills "$repo/.agents/skills"
  ln -s ../personal/ideas/plan.txt "$repo/outside-link"
  ln -s ../personal/x "$repo/personal-link"
  ln -s /etc/passwd "$repo/absolute-link"
  ln -s ../../x "$repo/nested/escape-link"
  ln -s z-chain-end "$repo/a-chain-start"
  ln -s ../personal/ideas/plan.txt "$repo/z-chain-end"
  ln -s a-reverse-end "$repo/z-reverse-start"
  ln -s ../personal/ideas/plan.txt "$repo/a-reverse-end"
  # Existing directory components must also be resolved (including before '..').
  ln -s .claude "$repo/internal-dir"
  ln -s internal-dir/skills "$repo/internal-chain"
  ln -s outside-link/../file "$repo/chain-parent"
  ln -s . "$repo/dot"
  ln -s .git "$repo/git-link"
  ln -s .GIT "$repo/git-case-link"
  ln -s dot/.git "$repo/git-alias-link"
  ln -s sub/../.git/hooks "$repo/git-parent-link"
}

assert_mirror_links() {
  local path
  [ "$(git -C "$MIRROR" config --bool core.symlinks)" = true ]
  [ -L "$MIRROR/.agents/skills" ]
  [ "$(readlink "$MIRROR/.agents/skills")" = ../.claude/skills ]
  [ "$(cat "$MIRROR/.agents/skills/x/SKILL.md")" = skill ]
  [ -L "$MIRROR/internal-chain" ]
  [ "$(cat "$MIRROR/internal-chain/x/SKILL.md")" = skill ]
  for path in outside-link personal-link absolute-link nested/escape-link a-chain-start z-chain-end z-reverse-start a-reverse-end chain-parent git-link git-case-link git-alias-link git-parent-link; do
    [ ! -L "$MIRROR/$path" ]
    [ ! -e "$MIRROR/$path" ]
  done
}

check_signpost_cycle() {
  local mode="$1" other="$ROOT/writer"
  make_fake_team_repo
  seed_repo "$EXPECTED_MIRROR_REMOTE" "$MIRROR" sub/file.txt
  [ "$mode" = writable ] || make_brain_readonly
  git clone -q "$EXPECTED_MIRROR_REMOTE" "$other"
  ln -s ../personal/ideas/plan.txt "$other/READ ME FIRST.txt"
  seed_mirror_links "$other"
  git -C "$other" add -A; git_commit "$other" 'symlink payload'
  git -C "$other" push -q origin main
  signpost_sentinel
  ONLINE_CHECK_REMOTE="$EXPECTED_MIRROR_REMOTE" run run_sync_cycle
  [ "$status" -eq 0 ]
  cmp "$ROOT/sentinel.expected" "$PERSONAL/ideas/plan.txt"
  [ ! -L "$MIRROR/READ ME FIRST.txt" ]
  assert_mirror_links
  grep -q "removed unsafe Brain symlink" "$LOG"
  grep -q "company's shared knowledge" "$MIRROR/READ ME FIRST.txt"
  # A second cycle exercises commit/protected restoration and repeated sanitization.
  ONLINE_CHECK_REMOTE="$EXPECTED_MIRROR_REMOTE" run run_sync_cycle
  [ "$status" -eq 0 ]
  assert_mirror_links
  cmp "$ROOT/sentinel.expected" "$PERSONAL/ideas/plan.txt"
}

@test "F2 read-only sync leaves the symlinked signpost's outside sentinel byte-identical" {
  check_signpost_cycle readonly
}

@test "F2 writable sync leaves the symlinked signpost's outside sentinel byte-identical" {
  check_signpost_cycle writable
}

check_sanitized_before_write() {
  local mode="$1" other="$ROOT/writer" writer_definition
  make_fake_team_repo
  seed_repo "$EXPECTED_MIRROR_REMOTE" "$MIRROR" sub/file.txt
  [ "$mode" = writable ] || make_brain_readonly
  git clone -q "$EXPECTED_MIRROR_REMOTE" "$other"
  seed_mirror_links "$other"
  ln -s ../personal/ideas/plan.txt "$other/READ ME FIRST.txt"
  git -C "$other" add -A; git_commit "$other" links
  git -C "$other" push -q origin main
  signpost_sentinel
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/sync.sh"
  writer_definition=$(declare -f write_generated_file)
  eval "${writer_definition/write_generated_file/original_write_generated_file}"
  write_generated_file() {
    local path
    for path in outside-link personal-link absolute-link nested/escape-link a-chain-start z-chain-end z-reverse-start a-reverse-end chain-parent git-link git-case-link git-alias-link git-parent-link 'READ ME FIRST.txt'; do
      if [ -L "$MIRROR/$path" ]; then
        echo "unsafe link still present before writing $1: $path" >&2
        touch "$ROOT/write-before-sanitize"
        return 1
      fi
    done
    original_write_generated_file "$@"
  }
  run sync_mirror
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT/write-before-sanitize" ]
  assert_mirror_links
  grep -q "company's shared knowledge" "$MIRROR/READ ME FIRST.txt"
  cmp "$ROOT/sentinel.expected" "$PERSONAL/ideas/plan.txt"
}

@test "F2 read-only checkout is sanitized before generated-file writes" {
  check_sanitized_before_write readonly
}

@test "F2 writable checkout is sanitized before generated-file writes" {
  check_sanitized_before_write writable
}

@test "F2 sanitizer handles dangling internal links, newline names and cyclic links" {
  source "$REPO_ROOT/lib/mirror_links.sh"
  mkdir -p "$MIRROR/dir"
  printf 'safe\n' > "$MIRROR/dir/"$'target\n'
  ln -s $'dir/target\n' "$MIRROR/newline-safe"
  ln -s dir/missing "$MIRROR/dangling-safe"
  ln -s ../personal/x "$MIRROR/"$'unsafe\nlink'
  ln -s cycle-b "$MIRROR/cycle-a"
  ln -s cycle-a "$MIRROR/cycle-b"
  chmod a-w "$MIRROR"
  run sanitize_mirror_links "$MIRROR"
  [ "$status" -eq 0 ]
  [ -L "$MIRROR/newline-safe" ]
  [ "$(cat "$MIRROR/newline-safe")" = safe ]
  [ -L "$MIRROR/dangling-safe" ]
  [ ! -L "$MIRROR/"$'unsafe\nlink' ]
  [ ! -L "$MIRROR/cycle-a" ]
  [ ! -L "$MIRROR/cycle-b" ]
  [ ! -w "$MIRROR" ]
}

@test "F2 generated signpost replaces symlinks and non-regular files in both modes" {
  source "$REPO_ROOT/lib/sync.sh"
  git init -q -b main "$MIRROR"
  signpost_sentinel
  local mode
  for mode in readonly writable; do
    ln -s ../personal/ideas/plan.txt "$MIRROR/$BRAIN_SIGNPOST"
    company_readme "$mode"
    cmp "$ROOT/sentinel.expected" "$PERSONAL/ideas/plan.txt"
    [ ! -L "$MIRROR/$BRAIN_SIGNPOST" ]
    rm "$MIRROR/$BRAIN_SIGNPOST"
    mkdir "$MIRROR/$BRAIN_SIGNPOST"
    company_readme "$mode"
    [ -f "$MIRROR/$BRAIN_SIGNPOST" ]
    rm "$MIRROR/$BRAIN_SIGNPOST"
  done
}

@test "F4 mirror clone never executes a committed post-checkout through global hooksPath" {
  make_fake_team_repo
  local writer="$ROOT/writer"
  seed_repo "$EXPECTED_MIRROR_REMOTE" "$writer" sub/file.txt
  mkdir -p "$writer/.githooks"
  printf '#!/bin/bash\ntouch "$BRAIN_ROOT/hook-ran"\n' > "$writer/.githooks/post-checkout"
  chmod +x "$writer/.githooks/post-checkout"
  seed_mirror_links "$writer"
  signpost_sentinel
  git -C "$writer" add -A; git_commit "$writer" hook
  git -C "$writer" push -q origin main
  git config --global core.hooksPath .githooks
  source "$REPO_ROOT/lib/complete_setup.sh"
  run complete_setup
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT/hook-ran" ]
  [ "$(git -C "$MIRROR" config core.hooksPath)" = "$MIRROR/.git/hooks" ]
  assert_mirror_links
  cmp "$ROOT/sentinel.expected" "$PERSONAL/ideas/plan.txt"
  [ -f "$MIRROR/sub/file.txt" ]
}

@test "F5 remote .agents skills including nested case variants never materialize in team" {
  make_fake_team_repo
  local other="$ROOT/writer" path
  git clone -q "$EXPECTED_TEAM_REMOTE" "$other"
  for path in .agents notes/.agents nested/.AgEnTs; do
    mkdir -p "$other/$path/skills/x"
    echo instruction > "$other/$path/skills/x/SKILL.md"
  done
  echo ordinary > "$other/ordinary.txt"
  git -C "$other" add -A; git_commit "$other" skills
  git -C "$other" push -q origin main
  ONLINE_CHECK_REMOTE="$EXPECTED_TEAM_REMOTE" run run_sync_cycle
  [ "$status" -eq 0 ]
  for path in .agents notes/.agents nested/.AgEnTs; do
    [ ! -e "$TEAM/$path" ]
  done
  [ "$(cat "$TEAM/ordinary.txt")" = ordinary ]
}

@test "F5 local .agents skills are excluded from staging without blocking ordinary notes" {
  make_fake_team_repo
  mkdir -p "$TEAM/.agents/skills/x" "$TEAM/nested/.AgEnTs/skills/x"
  echo instruction > "$TEAM/.agents/skills/x/SKILL.md"
  echo instruction > "$TEAM/nested/.AgEnTs/skills/x/SKILL.md"
  echo ordinary > "$TEAM/ordinary.txt"
  ONLINE_CHECK_REMOTE="$EXPECTED_TEAM_REMOTE" run run_sync_cycle
  [ "$status" -eq 0 ]
  git -C "$EXPECTED_TEAM_REMOTE" show main:ordinary.txt
  run git -C "$EXPECTED_TEAM_REMOTE" ls-tree -r --name-only main
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -qi '\.agents' || false
}

@test "F2 a failed generated-file producer preserves the previous bytes and cleans its temporary file" {
  source "$REPO_ROOT/lib/generated_files.sh"
  git init -q -b main "$MIRROR"
  printf 'previous\n' > "$MIRROR/generated.txt"
  cp "$MIRROR/generated.txt" "$ROOT/expected"
  failed_content() { printf 'partial\n'; return 1; }
  run write_generated_file "$MIRROR/generated.txt" failed_content
  [ "$status" -ne 0 ]
  cmp "$ROOT/expected" "$MIRROR/generated.txt"
  [ -z "$(find "$MIRROR" -name '.brain-sync.*' -print)" ]
}

@test "F2 generated metadata and hooks replace leaf symlinks without changing outside files" {
  make_fake_team_repo
  source "$REPO_ROOT/lib/team_layout.sh"
  source "$REPO_ROOT/lib/secretscan.sh"
  signpost_sentinel
  local p
  for p in info/exclude info/sparse-checkout hooks/pre-commit hooks/pre-push; do
    rm -f "$TEAM/.git/$p"
    ln -s "$PERSONAL/ideas/plan.txt" "$TEAM/.git/$p"
  done
  write_team_exclude "$TEAM"
  write_team_sparse_checkout "$TEAM"
  install_team_hooks "$TEAM" "$STATE/engine/lib"
  cmp "$ROOT/sentinel.expected" "$PERSONAL/ideas/plan.txt"
  for p in info/exclude info/sparse-checkout hooks/pre-commit hooks/pre-push; do
    [ ! -L "$TEAM/.git/$p" ]
    [ -f "$TEAM/.git/$p" ]
  done
}

@test "F2 conflict resolution replaces a symlink without writing outside the checkout" {
  source "$REPO_ROOT/lib/sync.sh"
  git init -q -b main "$MIRROR"
  signpost_sentinel
  local theirs ours mode
  theirs=$(printf 'incoming\n' | git -C "$MIRROR" hash-object -w --stdin)
  ours=$(printf 'local\n' | git -C "$MIRROR" hash-object -w --stdin)
  for mode in modify-delete union; do
    git -C "$MIRROR" update-index --force-remove conflict.txt
    printf '100644 %s 2\tconflict.txt\n' "$theirs" | git -C "$MIRROR" update-index --index-info
    if [ "$mode" = union ]; then
      printf '100644 %s 3\tconflict.txt\n' "$ours" | git -C "$MIRROR" update-index --index-info
    fi
    ln -s ../personal/ideas/plan.txt "$MIRROR/conflict.txt"
    (cd "$MIRROR" && resolve_conflict_file conflict.txt)
    cmp "$ROOT/sentinel.expected" "$PERSONAL/ideas/plan.txt"
    [ ! -L "$MIRROR/conflict.txt" ]
    grep -qx incoming "$MIRROR/conflict.txt"
    if [ "$mode" = union ]; then grep -qx local "$MIRROR/conflict.txt"; fi
    rm "$MIRROR/conflict.txt"
  done
}
