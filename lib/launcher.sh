#!/bin/bash
# AC-9: self-update from THIS repo (brain-sync), never from the Brain, with
# rollback to the last working copy when a new one fails to run. Installed
# by setup.sh outside the engine clone it manages, and self-contained (no
# `source` of engine files) so a broken update can't take down the rollback.
set -u
ROOT="${BRAIN_ROOT:-$HOME/Serlinolab}"
STATE="$ROOT/.state"; ENGINE="$STATE/engine"; LOG="$STATE/sync.log"
REMOTE="${BRAIN_SYNC_REMOTE:-https://github.com/serlinolab/brain-sync.git}"
mkdir -p "$STATE"
log(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

LOCK="$STATE/run.lock"
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
acquire_lock || exit 0

if [ ! -d "$ENGINE/.git" ]; then
  git clone --quiet "$REMOTE" "$ENGINE" >/dev/null 2>&1 || { log "self-update: initial clone failed"; exit 0; }
fi

cd "$ENGINE" || exit 0
prev=$(git rev-parse HEAD 2>/dev/null || echo "")
if git fetch --quiet origin main 2>/dev/null; then
  new=$(git rev-parse origin/main 2>/dev/null || echo "")
  if [ -n "$new" ] && [ "$new" != "$prev" ]; then
    git reset --quiet --hard origin/main
    if bash -n sync.sh lib/*.sh 2>>"$LOG" && bash sync.sh --selfcheck 2>>"$LOG"; then
      log "self-update: updated ${prev:-none} -> $new"
    else
      log "self-update: $new failed selfcheck, restoring ${prev:-none}"
      [ -n "$prev" ] && git reset --quiet --hard "$prev" && git clean -ffdqx
    fi
  fi
fi

[ "${1:-}" = "--selfcheck-only" ] && exit 0
BRAIN_SYNC_LOCK_HELD=1 bash "$ENGINE/sync.sh"
