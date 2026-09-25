#!/usr/bin/env bats
# 2026-09-25 (Max) - a conflict on a TEXT file no longer parks: it is resolved automatically
# with a union merge (`git merge-file --union`) that keeps every line from both sides, and the
# rebase carries straight on to the push. Only a BINARY conflict still parks (see
# team_two_way.bats / two_mac_os_junk.bats for that unchanged behaviour) - what counts as text
# is git's own judgement (git diff --numstat), never a file-extension list.
load 'helpers'
setup() { brain_test_setup; make_fake_team_repo; }
teardown() { brain_test_teardown; }

make_colleague_edit() {   # $1 = filename, $2 = content
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  printf '%s' "$2" > "$other/$1"
  git -C "$other" add -A; git_commit "$other" "colleague: $1"
  git -C "$other" push -q origin main
  rm -rf "$other"
}

# $1 = filename, $2 = source file to copy in - never via a bash command-substituted string
# (which silently truncates at a NUL byte), always a real file copy.
make_colleague_binary_edit() {
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  cp "$2" "$other/$1"
  git -C "$other" add -A; git_commit "$other" "colleague: $1"
  git -C "$other" push -q origin main
  rm -rf "$other"
}

# Case 1
@test "a text content conflict is resolved with a union merge, keeps both versions, and never parks" {
  make_colleague_edit note.txt $'the team\'s line\n'
  printf 'my line\n' > "$TEAM/note.txt"

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"

  [ "$status" -eq 0 ]
  [ ! -f "$MARK" ]
  [ ! -f "$CONFLICT_STATE" ]
  local remote; remote=$(git -C "$BRAIN_ROOT/origin-team.git" show main:note.txt)
  grep -qF "my line" <<<"$remote"
  grep -qF "the team's line" <<<"$remote"
  [ "$(cat "$TEAM/note.txt")" = "$remote" ]   # local disk matches what was pushed

  # AC-6: the incoming version is still saved, same as a parked conflict always kept it
  local saved; saved=$(find "$CONFLICTS" -name note.txt 2>/dev/null | head -1)
  [ -n "$saved" ]
  grep -qF "the team's line" "$saved"

  grep -q "note.txt" "$ROOT/what-changed.md"
  grep -qi "both versions were kept" "$ROOT/what-changed.md"
}

# Case 2
@test "text vs binary is git's own judgement, not a file-extension list" {
  # a .txt file whose CONTENT is binary (a NUL byte) still parks, extension notwithstanding -
  # the NUL byte is written straight to a file, never round-tripped through a bash command
  # substitution (which would silently truncate it).
  printf 'their\x00bytes' > "$BRAIN_ROOT/theirs-weird.bin"
  make_colleague_binary_edit weird.txt "$BRAIN_ROOT/theirs-weird.bin"
  printf 'my\x00bytes' > "$TEAM/weird.txt"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 3 ]
  [ -f "$MARK" ]

  # reset back to a clean, synced state before the second half of this test
  git -C "$TEAM" rebase --abort 2>/dev/null || true
  rm -f "$CONFLICT_STATE" "$MARK"
  git -C "$TEAM" fetch -q origin && git -C "$TEAM" reset -q --hard origin/main

  # a .bin file whose CONTENT is plain text still auto-merges, extension notwithstanding
  make_colleague_edit data.bin $'their data\n'
  printf 'my data\n' > "$TEAM/data.bin"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$MARK" ]
  local remote; remote=$(git -C "$BRAIN_ROOT/origin-team.git" show main:data.bin)
  grep -qF "my data" <<<"$remote"
  grep -qF "their data" <<<"$remote"
}

# Case 4
@test "add/add of the same new text file is treated as a text conflict with an empty base" {
  make_colleague_edit brand-new.txt $'their content\n'
  printf 'my content\n' > "$TEAM/brand-new.txt"   # same filename, never existed before, so no base

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"

  [ "$status" -eq 0 ]
  [ ! -f "$MARK" ]
  local remote; remote=$(git -C "$BRAIN_ROOT/origin-team.git" show main:brand-new.txt)
  grep -qF "my content" <<<"$remote"
  grep -qF "their content" <<<"$remote"
}

# Case 5
@test "a modify/delete conflict never loses content: the modified file is kept and logged" {
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  git -C "$other" rm -q note.txt
  git_commit "$other" "colleague: delete note.txt"
  git -C "$other" push -q origin main
  rm -rf "$other"

  echo "kept and changed locally" >> "$TEAM/note.txt"
  git -C "$TEAM" add note.txt; git_commit "$TEAM" "mine: modify note.txt"

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"

  [ "$status" -eq 0 ]
  [ ! -f "$MARK" ]
  git -C "$BRAIN_ROOT/origin-team.git" show main:note.txt | grep -qF "kept and changed locally"
  grep -q "note.txt" "$ROOT/what-changed.md"
}

# Case 6
@test "a rebase with several conflicting local commits resolves each step until it finishes" {
  make_colleague_edit note.txt $'colleague note\n'
  make_colleague_edit second.txt $'colleague second\n'

  printf 'my note\n' > "$TEAM/note.txt"
  git -C "$TEAM" add note.txt; git_commit "$TEAM" "mine: note"
  printf 'my second\n' > "$TEAM/second.txt"
  git -C "$TEAM" add second.txt; git_commit "$TEAM" "mine: second"

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"

  [ "$status" -eq 0 ]
  [ ! -f "$MARK" ]
  [ ! -f "$CONFLICT_STATE" ]
  local note second
  note=$(git -C "$BRAIN_ROOT/origin-team.git" show main:note.txt)
  second=$(git -C "$BRAIN_ROOT/origin-team.git" show main:second.txt)
  grep -qF "my note" <<<"$note"; grep -qF "colleague note" <<<"$note"
  grep -qF "my second" <<<"$second"; grep -qF "colleague second" <<<"$second"
}

@test "in a multi-step rebase, a binary conflict on any step aborts the whole rebase and parks" {
  make_colleague_edit note.txt $'colleague note\n'
  local theirs_bin="$BRAIN_ROOT/theirs.bin"
  { printf '\x00'; head -c 64 /dev/urandom; } > "$theirs_bin"
  make_colleague_binary_edit img.bin "$theirs_bin"

  printf 'my note\n' > "$TEAM/note.txt"
  git -C "$TEAM" add note.txt; git_commit "$TEAM" "mine: note"
  { printf '\x00'; head -c 64 /dev/urandom; } > "$TEAM/img.bin"
  git -C "$TEAM" add img.bin; git_commit "$TEAM" "mine: img"

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"

  [ "$status" -eq 3 ]
  [ -f "$MARK" ]
  # nothing partially applied - the text-only commit's content never reached the remote either
  ! git -C "$BRAIN_ROOT/origin-team.git" show main:note.txt 2>/dev/null | grep -qF "my note"
  [ ! -d "$(git -C "$TEAM" rev-parse --git-path rebase-merge)" ]
}

# Case 8
@test "the local person stays the commit author after an auto-merged conflict, and the secret-scan hook still runs" {
  make_colleague_edit note.txt $'colleague note\n'
  printf 'my note\n' > "$TEAM/note.txt"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -eq 0 ]
  git -C "$BRAIN_ROOT/origin-team.git" log -1 --format='%an' main | grep -qF "testperson"

  # a secret-looking commit is refused by the same pre-commit hook whether it is made directly
  # or produced by auto_rebase_onto_origin's own `git rebase --continue` - auto-merge never
  # bypasses it. --no-verify only seeds the precondition (a local commit already carrying
  # secret-looking content, however it got there); sync.sh itself never passes --no-verify.
  git -C "$TEAM" fetch -q origin && git -C "$TEAM" reset -q --hard origin/main
  make_colleague_edit note.txt $'colleague again\n'
  printf 'AKIAABCDEFGHIJKLMNOP\n' > "$TEAM/note.txt"
  git -C "$TEAM" add note.txt
  git -C "$TEAM" -c user.name=fixture -c user.email=fixture@example.com \
    commit --no-verify -qm "mine: secret-looking"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"
  [ "$status" -ne 0 ]
  ! git -C "$BRAIN_ROOT/origin-team.git" show main:note.txt | grep -qF "AKIAABCDEFGHIJKLMNOP"
}
