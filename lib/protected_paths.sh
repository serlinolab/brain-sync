#!/bin/bash
# MAX-1790: the Brain paths that are NEVER committed from a Mac. The ONE place the list lives.
# It must mean the same as the push ruleset on serlinolab/Serlinolab-Brain (docs/runbook.md,
# "Editing the Brain directly"): the ruleset is the server-side layer, this is the engine's own.
# CASE-INSENSITIVE, like the ruleset (GitHub refused notes/claude.md, notes/Agents.md and
# .CLAUDE/skills/x/SKILL.md, verified 2026-10-09). It has to be on a Mac: APFS is case-insensitive
# by default, so `claude.md` IS CLAUDE.md and `.CLAUDE` IS `.claude` - the file loads as instructions.
# Names and directories below are written in their canonical case; matching ignores it.
BRAIN_PROTECTED_NAMES=(CLAUDE.md CLAUDE.local.md AGENTS.md)   # at any depth
BRAIN_PROTECTED_DIRS=(.claude .agents)                         # a directory of this name, at any depth
BRAIN_PROTECTED_TOP=(method)                                   # top level only
# Written by the nightly export, never by a person.
BRAIN_PROTECTED_FILES=(
  audits/latest-weekly.md company/stock-status.md competitors/README.md
  voice-of-customer/corpus-profile.md voice-of-customer/phrase-bank-it.md
  voice-of-customer/phrase-bank-us.md voice-of-customer/support-requests.md
)

# 0 if the repo-relative path is protected. A path counts if ANY component matches a name or a
# directory above, so the `.agents` symlink itself (it points at .claude/skills) is protected too.
brain_path_protected(){
  local p="${1#./}" c hit=1 was_off=1
  local -a parts
  shopt -q nocasematch && was_off=0
  shopt -s nocasematch   # [[ == ]] and case ignore case from here; restored below
  for c in "${BRAIN_PROTECTED_FILES[@]}"; do [[ "$p" == "$c" ]] && hit=0; done
  for c in "${BRAIN_PROTECTED_TOP[@]}"; do case "$p" in "$c"|"$c"/*) hit=0 ;; esac; done
  IFS=/ read -ra parts <<<"$p"
  for p in "${parts[@]}"; do
    for c in "${BRAIN_PROTECTED_NAMES[@]}" "${BRAIN_PROTECTED_DIRS[@]}"; do [[ "$p" == "$c" ]] && hit=0; done
  done
  [ "$was_off" -eq 1 ] && shopt -u nocasematch
  return "$hit"
}

# The same list as `git add` exclude pathspecs - the second layer, in case a protected path ever
# slips past the restore step. The "agree" test in tests/brain_two_way.bats proves it matches the
# predicate. `icase` makes git fold case in the pathspec, as the predicate does.
brain_protected_excludes(){
  local n
  for n in "${BRAIN_PROTECTED_NAMES[@]}"; do printf ':(exclude,glob,icase)**/%s\n' "$n"; done
  for n in "${BRAIN_PROTECTED_DIRS[@]}"; do printf ':(exclude,glob,icase)**/%s\n:(exclude,glob,icase)**/%s/**\n' "$n" "$n"; done
  for n in "${BRAIN_PROTECTED_TOP[@]}"; do printf ':(exclude,glob,icase)%s\n:(exclude,glob,icase)%s/**\n' "$n" "$n"; done
  for n in "${BRAIN_PROTECTED_FILES[@]}"; do printf ':(exclude,literal,icase)%s\n' "$n"; done
}
