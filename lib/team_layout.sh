#!/bin/bash
# Single source of truth for the team/ sparse-checkout pattern (MAX-1515 review, Class A;
# amended when Serlinolab_Brain/ moved beside team/, no longer nested inside it).
# Sourced by setup.sh (the real install) and tests/helpers.bash (test doubles), so the
# patterns a test asserts against can never drift from what setup.sh actually installs.
#
# The instruction-file names excluded from team/, shared by the sparse-checkout below (what a
# colleague's push can ever check out) and by lib/sync.sh's `git add` pathspec (what a
# creator's own untracked file can ever be staged from) - one array, so the two exclusion
# views can never drift apart (MAX-1515 fix 1).
TEAM_INSTRUCTION_NAMES=(CLAUDE.md CLAUDE.local.md AGENTS.md .claude)

# `!name` alone only excludes a FILE or SYMLINK named `name` - a colleague (or a local, never-
# pulled file - MAX-1515 fix 4) can instead commit `name` as a DIRECTORY, with its own files
# underneath. Excluding both the bare name and its `/**` descendants covers every object type
# regardless of how git classifies it, for every name here, not just .claude.
#
# Pure content generator, no git calls - the one place the pattern's TEXT is built, so
# write_team_sparse_checkout (the installer) and team_is_protected (lib/complete_setup.sh's
# verifier, MAX-1515 review finding B) can never drift into checking two different patterns.
team_sparse_checkout_pattern(){
  local name
  printf '/*\n'
  for name in "${TEAM_INSTRUCTION_NAMES[@]}"; do
    printf '!%s\n' "$name"
    printf '!%s/**\n' "$name"
  done
}

write_team_sparse_checkout(){
  local team="$1"
  git -C "$team" sparse-checkout init --no-cone >/dev/null 2>&1 || return 1
  team_sparse_checkout_pattern > "$team/.git/info/sparse-checkout" || return 1
  git -C "$team" sparse-checkout reapply >/dev/null 2>&1 || return 1
}

# MAX-1515 fix 1: the pathspec exclusions for `git add -A` in lib/sync.sh's commit_local - a
# local, untracked instruction file (never pulled from a colleague) only matching an EXCLUDED
# sparse-checkout pattern makes a bare `git add -A` exit 1 ("outside of your sparse-checkout
# definition"), which used to wedge every future sync cycle before it ever reached the
# network. `icase` because the Mac's filesystem is case-insensitive by default, so a
# differently-cased instruction file is still the same file as far as this creator's Mac is
# concerned. Independent of any .gitignore content - a colleague committing `!.claude` cannot
# re-open this.
#
# MAX-1515 fix 4: every name gets both the bare exclude AND its `/**` descendants, not just
# .claude - a local directory named e.g. AGENTS.md/ (or one nested a level down) wedged
# `git add -A` otherwise: the bare pathspec never matched the file INSIDE it, so `git add`
# tried to stage a path outside the sparse-checkout definition and exited 1, stopping every
# future cycle before it ever reached the network.
team_add_exclude_pathspecs(){
  local name
  for name in "${TEAM_INSTRUCTION_NAMES[@]}"; do
    printf ':(exclude,glob,icase)**/%s\n' "$name"
    printf ':(exclude,glob,icase)**/%s/**\n' "$name"
  done
  local p
  for p in "${TEAM_OS_JUNK_PATTERNS[@]}"; do
    printf ':(exclude,glob)**/%s\n' "$p"
  done
}

# 2026-09-24 live incident: Finder writes/rewrites these into any folder it opens, on its own
# schedule, forever. Tracking any of them makes team/'s working tree "dirty" again the instant
# it is cleaned, which is what turned an ordinary sync cycle into a permanently-dirty tree and
# then a false rebase "conflict" (lib/sync.sh's sync_team). One array - lib/sync.sh's
# heal_local_junk_history and commit_local, and team_add_exclude_pathspecs above, all read the
# SAME list so none of them can drift from what is actually excluded.
TEAM_OS_JUNK_PATTERNS=(.DS_Store '._*' .AppleDouble .Spotlight-V100 .Trashes .fseventsd 'Icon?' '*.icloud')

# `.git/info/exclude` is per-clone and local-only - unlike a tracked .gitignore, a colleague's
# push can never edit or override it. Regenerated every cycle (both by a fresh setup, via
# complete_setup, and by an already-set-up Mac's own sync cycle, via commit_local) so existing
# Macs heal themselves without waiting for a fresh clone.
write_team_exclude(){
  local team="$1"
  mkdir -p "$team/.git/info" || return 1
  local p
  { for p in "${TEAM_OS_JUNK_PATTERNS[@]}"; do printf '%s\n' "$p"; done; } > "$team/.git/info/exclude"
}

# Pathspecs for `git rm`/`git log`/`git diff` (porcelain plumbing, not the exclude file's
# gitignore syntax) - matches TEAM_OS_JUNK_PATTERNS at any depth.
team_os_junk_pathspecs(){
  local p
  for p in "${TEAM_OS_JUNK_PATTERNS[@]}"; do
    printf ':(glob)**/%s\n' "$p"
  done
}
