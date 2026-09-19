#!/bin/bash
# shellcheck disable=SC2034  # a constants file: every name here is used by a sibling, not locally
# Shared paths, constants, logging and the lock. Sourced by sync.sh and
# tests (override BRAIN_ROOT in tests instead of the real $HOME/Serlino).
ROOT="${BRAIN_ROOT:-$HOME/Serlino}"
STATE="$ROOT/.state"
MIRROR="$ROOT/serlinolab"
TEAM="$ROOT/team"
PERSONAL="$ROOT/personal/shared"
LOG="$STATE/sync.log"
MARK="$ROOT/SOMETHING NEEDS YOUR ATTENTION.txt"
LOCK="$STATE/run.lock"
STALE_HOURS="${STALE_HOURS:-4}"
CONFLICT_STATE="$STATE/conflict_attempts"
MAX_CONFLICT_ATTEMPTS=3          # AC-5: named constant, never a literal in the check
ONLINE_CHECK_REMOTE="${ONLINE_CHECK_REMOTE:-git@brain-mirror:serlinolab/Serlinolab-Brain.git}"
mkdir -p "$STATE" 2>/dev/null

log(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

# AC-4: mkdir is atomic across processes; a lock left by a dead process is broken, not waited on.
acquire_lock(){
  if ! mkdir "$LOCK" 2>/dev/null; then
    if [ -f "$LOCK/pid" ] && ! kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then
      log "breaking stale lock from pid $(cat "$LOCK/pid")"
      rm -rf "$LOCK"
      mkdir "$LOCK" 2>/dev/null || return 1
    else
      return 1
    fi
  fi
  echo $$ > "$LOCK/pid"
  trap 'rm -rf "$LOCK"' EXIT INT TERM
  return 0
}
