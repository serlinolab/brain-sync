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
# Written once by setup.sh. It used to fall back to `basename "$PERSONAL"`, which is the
# literal string "shared" for everyone - every creator's notes would have been committed as
# one identity. Attribution is tied to pay (MAX-1515 AC-8), so an unknown person is recorded
# as unknown and logged, never quietly merged into someone else.
PERSON_FILE="$STATE/person"
PERSON_SLUG="${BRAIN_PERSON_SLUG:-}"
[ -n "$PERSON_SLUG" ] || PERSON_SLUG=$(cat "$PERSON_FILE" 2>/dev/null || true)
if [ -z "$PERSON_SLUG" ]; then PERSON_SLUG="unknown"; PERSON_UNKNOWN=1; else PERSON_UNKNOWN=0; fi
GIT_IDENTITY_NAME="Serlino Brain ($PERSON_SLUG)"
GIT_IDENTITY_EMAIL="brain-$PERSON_SLUG@$(hostname -s).local"
mkdir -p "$STATE" 2>/dev/null

# deferred until log() exists
person_warn(){ [ "$PERSON_UNKNOWN" = 1 ] && log "no person recorded in $PERSON_FILE; authoring as unknown"; return 0; }

log(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

# AC-4: mkdir is atomic across processes; a stale lock is renamed atomically.
acquire_lock(){
  if ! mkdir "$LOCK" 2>/dev/null; then
    if [ -f "$LOCK/pid" ] && ! kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then
      local stale="$LOCK.stale.$$"
      log "breaking stale lock from pid $(cat "$LOCK/pid")"
      mv "$LOCK" "$stale" 2>/dev/null || return 1
      rm -f "$stale/pid"
      rmdir "$stale" 2>/dev/null || true
    else
      return 1
    fi
  fi
  echo $$ > "$LOCK/pid"
  trap 'rm -rf "$LOCK"' EXIT INT TERM
  return 0
}
