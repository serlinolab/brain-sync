#!/usr/bin/env bats
# 2026-09-24 live incident (fix/team-sync-os-junk-and-dirty-rebase): Finder writes/rewrites
# .DS_Store into any folder it opens, forever. Tracking it made team/'s working tree "dirty"
# again the instant it was cleaned, which turned an ordinary sync into a permanently dirty
# tree and then a false rebase "conflict" - and, on Max's Mac, a conflict latch that never
# unparked, so nothing reached the remote for hours. These tests cover: junk is never tracked
# (root cause 1), a dirty tree from junk is never treated as a content conflict (root cause
# 2), a push failure reports its real cause (root cause 3), and an already-set-up Mac's local
# history heals itself of junk it committed before this fix existed (root cause 4).
load 'helpers'
setup() { brain_test_setup; make_fake_team_repo; }
teardown() { brain_test_teardown; }

@test "the exclude file is written for a freshly configured team clone" {
  grep -qx '.DS_Store' "$TEAM/.git/info/exclude"
}

@test ".DS_Store is never tracked even though something keeps rewriting it, and the tree ends up clean" {
  echo 'finder bytes 1' > "$TEAM/.DS_Store"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run_sync_cycle
  ! git -C "$TEAM" ls-files --error-unmatch .DS_Store >/dev/null 2>&1
  echo 'finder bytes 2 (rewritten)' > "$TEAM/.DS_Store"   # Finder touches it again
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run_sync_cycle
  ! git -C "$TEAM" ls-files --error-unmatch .DS_Store >/dev/null 2>&1
  [ -z "$(git -C "$TEAM" status --porcelain)" ]   # untracked-but-ignored: not "dirty"
  [ ! -f "$CONFLICT_STATE" ]
  [ ! -f "$MARK" ]
}

@test "an already-tracked .DS_Store (pre-fix state) is untracked on the next cycle, file kept on disk" {
  echo 'legacy tracked junk' > "$TEAM/.DS_Store"
  git -C "$TEAM" add -f .DS_Store; git_commit "$TEAM" 'oops, tracked .DS_Store'
  git -C "$TEAM" ls-files --error-unmatch .DS_Store >/dev/null

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run_sync_cycle

  ! git -C "$TEAM" ls-files --error-unmatch .DS_Store >/dev/null 2>&1
  [ -f "$TEAM/.DS_Store" ]   # never deleted, only untracked
}

@test "nested OS junk (a subdirectory's .DS_Store, an AppleDouble ._file) is excluded too" {
  mkdir -p "$TEAM/sub/dir"
  echo x > "$TEAM/sub/dir/.DS_Store"
  echo x > "$TEAM/sub/._resource"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run_sync_cycle
  ! git -C "$TEAM" ls-files --error-unmatch sub/dir/.DS_Store >/dev/null 2>&1
  ! git -C "$TEAM" ls-files --error-unmatch sub/._resource >/dev/null 2>&1
}

@test "a dirty tracked file rewritten between commit and rebase is autostashed, never counted as a conflict" {
  # Simulates the exact failure mode: something rewrites a TRACKED file after commit_local's
  # own commit but before sync_team's rebase (in a real cycle this was .DS_Store; here it is
  # any tracked file, to prove the autostash fix is general, not a .DS_Store special case).
  # A genuinely different, non-conflicting colleague commit must still land cleanly.
  local other; other="$(mktemp -d)"
  git clone -q "$BRAIN_ROOT/origin-team.git" "$other"
  echo "colleague content" > "$other/colleague.txt"
  git -C "$other" add -A; git_commit "$other" colleague
  git -C "$other" push -q origin main
  rm -rf "$other"

  echo "mine" > "$TEAM/mine.txt"
  git -C "$TEAM" add -A; git_commit "$TEAM" mine
  echo "dirtied after the commit, before the rebase" >> "$TEAM/mine.txt"   # tracked, unstaged

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"

  [ "$(cat "$TEAM/colleague.txt")" = "colleague content" ]
  grep -q "dirtied after the commit" "$TEAM/mine.txt"   # the dirty edit survived (autostash pop)
  [ ! -f "$CONFLICT_STATE" ]
  [ ! -f "$MARK" ]
  ! grep -q "CONFLICT parked" "$LOG"
}

@test "a push failure logs the real git error, not just 'push failed' with no cause" {
  # Fetch/rebase must still succeed (same URL, readable) - only the write side fails, so the
  # log line has to come from the push step itself, carrying git's own explanation.
  echo "mine" > "$TEAM/mine.txt"
  git -C "$TEAM" add -A; git_commit "$TEAM" mine
  chmod -R a-w "$BRAIN_ROOT/origin-team.git"

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"

  chmod -R u+w "$BRAIN_ROOT/origin-team.git"
  grep -q "push failed:" "$LOG"
  ! grep -q "^push failed$" "$LOG"   # the old bare, causeless line is gone
}

@test "local commits that carried .DS_Store are rewritten before push: the junk never reaches origin, the real note does" {
  # Reproduces Max's Mac: several cycles of a tracked .DS_Store, one of them alongside a real
  # note edit, all unpushed. Seed that state by hand (what the pre-fix engine would have
  # committed), then run the fixed engine and check what actually reaches the bare remote.
  echo 'junk 1' > "$TEAM/.DS_Store"; git -C "$TEAM" add -f .DS_Store; git_commit "$TEAM" 'notes 1'
  echo 'junk 2' > "$TEAM/.DS_Store"; git -C "$TEAM" add -f .DS_Store; git_commit "$TEAM" 'notes 2'
  echo 'junk 3' > "$TEAM/.DS_Store"; git -C "$TEAM" add -f .DS_Store
  echo 'the real note' >> "$TEAM/note.txt"
  git -C "$TEAM" add -A; git_commit "$TEAM" 'notes 3'
  [ "$(git -C "$TEAM" rev-list --count origin/main..HEAD)" -eq 3 ]

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"

  # the real content reached the remote
  git -C "$BRAIN_ROOT/origin-team.git" show main:note.txt | grep -q "the real note"
  # no commit that reached the remote carries .DS_Store in its tree
  ! git -C "$BRAIN_ROOT/origin-team.git" log --name-only --all -- ':(glob)**/.DS_Store' | grep -q DS_Store
  # and no blob matching the junk content is reachable at all
  ! git -C "$BRAIN_ROOT/origin-team.git" cat-file --batch-all-objects --batch-check 2>/dev/null \
      | awk '$2=="blob"{print $1}' \
      | xargs -I{} git -C "$BRAIN_ROOT/origin-team.git" cat-file -p {} 2>/dev/null \
      | grep -q "^junk"
}

@test "a stale conflict park caused purely by junk is cleared once the local history is cleaned, and retried" {
  echo "$MAX_CONFLICT_ATTEMPTS" > "$CONFLICT_STATE"   # simulates being latched shut from before the fix
  echo 'junk' > "$TEAM/.DS_Store"; git -C "$TEAM" add -f .DS_Store; git_commit "$TEAM" 'tracked junk, pre-fix'

  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run bash "$REPO_ROOT/sync.sh"

  # 2026-09-25: the retry-at-the-bound path is now shared with the text-conflict auto-merge
  # feature (case 7) - the log line changed shape but the outcome (latch cleared on retry,
  # junk cleaned) is the same.
  grep -q "cleared a parked conflict on retry" "$LOG"
  grep -q "local history also cleaned of OS junk" "$LOG"
  [ "$status" -eq 0 ]
  [ ! -f "$CONFLICT_STATE" ]
  git -C "$BRAIN_ROOT/origin-team.git" rev-parse main >/dev/null
}

@test "a file inside a directory-shaped junk name (.Trashes/, .fseventsd/) is excluded too, not just the bare directory" {
  mkdir -p "$TEAM/.Trashes" "$TEAM/.fseventsd" "$TEAM/.Spotlight-V100" "$TEAM/.AppleDouble"
  echo x > "$TEAM/.Trashes/deleted-thing"
  echo x > "$TEAM/.fseventsd/0000000012345"
  echo x > "$TEAM/.Spotlight-V100/store.db"
  echo x > "$TEAM/.AppleDouble/resource"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run_sync_cycle
  ! git -C "$TEAM" ls-files --error-unmatch .Trashes/deleted-thing >/dev/null 2>&1
  ! git -C "$TEAM" ls-files --error-unmatch .fseventsd/0000000012345 >/dev/null 2>&1
  ! git -C "$TEAM" ls-files --error-unmatch .Spotlight-V100/store.db >/dev/null 2>&1
  ! git -C "$TEAM" ls-files --error-unmatch .AppleDouble/resource >/dev/null 2>&1
}

@test "junk exclusion is case-insensitive, matching a Mac's case-insensitive filesystem" {
  echo x > "$TEAM/.ds_store"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/origin-team.git" run_sync_cycle
  ! git -C "$TEAM" ls-files --error-unmatch .ds_store >/dev/null 2>&1
}
