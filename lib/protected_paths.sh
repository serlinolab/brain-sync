#!/bin/bash
# MAX-1790: the Brain paths that are NEVER committed from a Mac. The ONE place the list lives.
# It must mean the same as the push ruleset on serlinolab/Serlinolab-Brain (docs/runbook.md,
# "Editing the Brain directly"): the ruleset is the server-side layer, this is the engine's own.
# Case-sensitive, like the ruleset.
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
  local p="${1#./}" c
  local -a parts
  for c in "${BRAIN_PROTECTED_FILES[@]}"; do [ "$p" = "$c" ] && return 0; done
  for c in "${BRAIN_PROTECTED_TOP[@]}"; do case "$p" in "$c"|"$c"/*) return 0 ;; esac; done
  IFS=/ read -ra parts <<<"$p"
  for p in "${parts[@]}"; do
    for c in "${BRAIN_PROTECTED_NAMES[@]}" "${BRAIN_PROTECTED_DIRS[@]}"; do [ "$p" = "$c" ] && return 0; done
  done
  return 1
}

# The same list as `git add` exclude pathspecs - the second layer, in case a protected path ever
# slips past the restore step. tests/brain_protected_paths.bats proves it agrees with the predicate.
brain_protected_excludes(){
  local n
  for n in "${BRAIN_PROTECTED_NAMES[@]}"; do printf ':(exclude,glob)**/%s\n' "$n"; done
  for n in "${BRAIN_PROTECTED_DIRS[@]}"; do printf ':(exclude,glob)**/%s\n:(exclude,glob)**/%s/**\n' "$n" "$n"; done
  for n in "${BRAIN_PROTECTED_TOP[@]}"; do printf ':(exclude,glob)%s\n:(exclude,glob)%s/**\n' "$n" "$n"; done
  for n in "${BRAIN_PROTECTED_FILES[@]}"; do printf ':(exclude,literal)%s\n' "$n"; done
}
