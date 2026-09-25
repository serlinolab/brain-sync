#!/bin/bash
# shellcheck disable=SC2034  # a constants file: every name here is used by a sibling, not locally
# Shared paths, constants, logging and the lock. Sourced by sync.sh and
# tests (override BRAIN_ROOT in tests instead of the real $HOME/Serlinolab).
# Codex re-review of 0b5862b, non-blocking: none of `git ls-remote`/`fetch`/`push` had a
# timeout, and setup.sh's `append_host` only ever writes the `~/.ssh/config` Host block ONCE
# (it is a no-op once the block already exists - see append_host there), so adding options to
# that template would only ever reach a Mac set up AFTER this ships, never Max's or Karl's
# already-stuck Macs. Setting it here instead reaches every Mac the moment the engine
# self-updates, for every git network call this process makes, with no dependency on setup.sh
# ever running again. Only set when not already overridden by the environment.
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15}"
ROOT="${BRAIN_ROOT:-$HOME/Serlinolab}"
STATE="$ROOT/.state"
TEAM="$ROOT/team"                 # MAX-1515: two-way, everyone writes
MIRROR="$ROOT/Serlinolab_Brain"   # MAX-1515 (amended): beside team/, not nested inside it, read-only
PERSONAL="$ROOT/personal"         # MAX-1515: plain folders, no git, engine never touches this
LOG="$STATE/sync.log"
MARK="$ROOT/SOMETHING NEEDS YOUR ATTENTION.txt"
LOCK="$STATE/run.lock"
STALE_HOURS="${STALE_HOURS:-4}"
# MAX-1515 change A: how long setup may sit pending (a deploy key not yet registered, or its
# clone/configure step failing) before update_attention_marker raises "SOMETHING NEEDS YOUR
# ATTENTION.txt" about it. Overridable the same way STALE_HOURS is.
SETUP_PENDING_ALERT_HOURS="${SETUP_PENDING_ALERT_HOURS:-24}"
CONFLICT_STATE="$STATE/conflict_attempts"
MAX_CONFLICT_ATTEMPTS=3          # AC-5: named constant, never a literal in the check
# Case 7 fix (2026-09-25): origin/main + local HEAD SHAs recorded at the moment a park at the
# bound survives a retry, so the NEXT cycle can tell "nothing could have changed" (skip, no new
# conflict copy) from "something moved" (worth a real retry) - see sync_team. Missing/empty
# (a park recorded before this fix, or a fresh park) always counts as "changed".
CONFLICT_PARK_SHAS="$STATE/conflict_park_shas"
CONFLICTS="$STATE/conflicts"      # AC-6: incoming copy of each conflicting file is saved here
# Codex re-review of 0b5862b: set by sync_team when an autostash it created itself (never a
# pre-existing, unrelated stash - see the delta check in lib/sync.sh) fails to reapply after a
# rebase, so update_attention_marker can raise a plain-language marker instead of the Mac
# wedging silently. Cleared by update_attention_marker itself once the stash is actually gone
# (re-derived from real state, AC-7 - never trusted as a standing flag on its own).
AUTOSTASH_CONFLICT_STATE="$STATE/autostash_conflict"
QUARANTINE="$STATE/quarantine"    # AC-4: locally-created instruction files are moved here, never deleted
ONLINE_CHECK_REMOTE="${ONLINE_CHECK_REMOTE:-git@brain-mirror:serlinolab/Serlinolab-Brain.git}"
# MAX-1515 fix 4b: what setup.sh ever adopts or creates team/ and the mirror against - the
# engine re-checks a repo's origin against these before every cycle's mutating operations, so
# a repo whose origin was changed after setup ran is never trusted just because it sits at the
# right path. Overridable the same way ONLINE_CHECK_REMOTE already is, for the same reason
# (a test double rewrites the URL going in).
EXPECTED_TEAM_REMOTE="${EXPECTED_TEAM_REMOTE:-git@brain-team:serlinolab/brain-team.git}"
EXPECTED_MIRROR_REMOTE="${EXPECTED_MIRROR_REMOTE:-git@brain-mirror:serlinolab/Serlinolab-Brain.git}"
# Written once by setup.sh. It used to fall back to `basename "$PERSONAL"`, which is the
# literal string "shared" for everyone - every creator's notes would have been committed as
# one identity. Attribution is tied to pay (MAX-1515 AC-8), so an unknown person is recorded
# as unknown and logged, never quietly merged into someone else.
PERSON_FILE="$STATE/person"
PERSON_SLUG="${BRAIN_PERSON_SLUG:-}"
[ -n "$PERSON_SLUG" ] || PERSON_SLUG=$(cat "$PERSON_FILE" 2>/dev/null || true)
case "$PERSON_SLUG" in
  ''|*[!a-z0-9-]*) PERSON_SLUG="unknown"; PERSON_UNKNOWN=1 ;;
  *) PERSON_UNKNOWN=0 ;;
esac
GIT_IDENTITY_NAME="Serlino Brain ($PERSON_SLUG)"
GIT_IDENTITY_EMAIL="brain-$PERSON_SLUG@$(hostname -s).local"
mkdir -p "$STATE" 2>/dev/null

# deferred until log() exists
person_warn(){ [ "$PERSON_UNKNOWN" = 1 ] && log "no person recorded in $PERSON_FILE; authoring as unknown"; return 0; }

log(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

# AC-4: mkdir is atomic across processes; a stale lock is renamed atomically.
# --- lock: IDENTICAL COPY in lib/common.sh and lib/launcher.sh (tests assert byte equality).
# The launcher must not source engine files, or a broken update could take down its own
# rollback, so this is duplicated on purpose rather than shared.
#
# A cycle runs every 300s and takes seconds, so SKIPPING one is harmless while running two at
# once is not. Every ambiguity below therefore fails closed.
#
# Staleness is decided by AGE, never by a pid. Three rounds of review broke the pid version,
# each time differently, and both remaining failures were structural: the pid file cannot be
# written atomically with the mkdir that creates the lock, so a crash in between left a lock
# nobody could ever break (the Mac stops syncing forever, silently), and a pid reused after a
# reboot made a stranger look like the owner. Neither is reachable without consulting pids.
LOCK_STALE_SECONDS="${LOCK_STALE_SECONDS:-1800}"

_lock_age_seconds(){
  local t; t=$(stat -f %m "$1" 2>/dev/null) || return 1
  echo $(( $(date +%s) - t ))
}

acquire_lock(){
  if ! mkdir "$LOCK" 2>/dev/null; then
    local age; age=$(_lock_age_seconds "$LOCK") || return 1
    # Two checks, and they are not redundant even though removing this one keeps every test
    # green and every probe clean (measured: 6 runs, 3 contenders against a live holder, 0
    # intruders either way). The SAFETY property is the seized-age re-check below. This one
    # narrows the window: without it every contender moves the live lock aside and puts it
    # back, so $LOCK briefly does not exist on each attempt. Keep both; do not "simplify".
    [ "$age" -ge "$LOCK_STALE_SECONDS" ] || return 1
    local seized="$LOCK.dead.$$"
    mv "$LOCK" "$seized" 2>/dev/null || return 1
    # Only one contender can win that rename, but it was judged BEFORE the rename: if another
    # contender took over in between we have just seized a live lock. Detect it by the age of
    # what we actually got, put it back, and give up. The exposure is the microseconds between
    # the two calls, and we never proceed.
    local got; got=$(_lock_age_seconds "$seized")
    if [ -z "$got" ] || [ "$got" -lt "$LOCK_STALE_SECONDS" ]; then
      mv "$seized" "$LOCK" 2>/dev/null || rm -rf "$seized"
      return 1
    fi
    log "broke a lock abandoned ${got}s ago"
    rm -rf "$seized"
    mkdir "$LOCK" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" > "$LOCK/pid"   # informational for an operator reading the folder; never arbitration
  # shellcheck disable=SC2329  # invoked indirectly by trap
  cleanup_lock(){
    [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"
    return 0
  }
  trap 'cleanup_lock' EXIT
  trap 'cleanup_lock; exit 130' INT
  trap 'cleanup_lock; exit 143' TERM
  return 0
}
