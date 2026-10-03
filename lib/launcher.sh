#!/bin/bash
# AC-9: self-update from THIS repo (brain-sync), never from the Brain, with
# rollback to the last working copy when a new one fails to run. Installed
# by setup.sh outside the engine clone it manages, and self-contained (no
# `source` of engine files) so a broken update can't take down the rollback.
set -u
ROOT="${BRAIN_ROOT:-$HOME/Serlinolab}"
STATE="$ROOT/.state"; ENGINE="$STATE/engine"; LOG="$STATE/sync.log"
REMOTE="${BRAIN_SYNC_REMOTE:-https://github.com/serlinolab/brain-sync.git}"
# The self-update's https git had no limit either: a transfer below 1000 bytes/s for 60 s is now
# abandoned (git's own low-speed limit) instead of hanging the cycle. Exported, so sync.sh and every
# git it runs inherit it too.
export GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1000}"
export GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-60}"
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

# capability: safe-stop
# (Read by the SerlinoLab Brain app before it uses `launchctl kickstart -k` on a stuck run.)
#
# Every long step (clone, fetch, selfcheck, the cycle itself) runs as a background child that this
# script WAITS for: bash runs a trap only once a foreground command returns, but interrupts `wait`
# at once. So TERM (what `kickstart -k` and logout send) stops whatever is running in ANY phase and
# frees the lock immediately, well inside launchd's 20 s before it would SIGKILL us - a SIGKILLed
# launcher leaves the lock for LOCK_STALE_SECONDS (MAX-1629, 2026-10-03).
STOP_GRACE_SECONDS=5
CHILD_PID=""
# The pid and all its descendants, children first (collected BEFORE signalling, so a process that
# outlives its parent is still on the list for the KILL pass).
tree_pids(){
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do tree_pids "$child"; done
  printf '%s\n' "$1"
}
stop_tree(){
  local pids p i alive
  pids=$(tree_pids "$1")
  for p in $pids; do kill -TERM "$p" 2>/dev/null; done
  for i in $(seq 1 "$STOP_GRACE_SECONDS"); do
    alive=""
    for p in $pids; do kill -0 "$p" 2>/dev/null && { alive=1; break; }; done
    [ -z "$alive" ] && return 0
    sleep 1
  done
  for p in $pids; do kill -KILL "$p" 2>/dev/null; done
}
# Every direct child of this launcher, not just CHILD_PID: a TERM can land between a `&` and the
# assignment of `$!`, and the watchdog is a child too.
stop_all(){
  local child
  for child in $(pgrep -P $$ 2>/dev/null); do stop_tree "$child"; done
}
trap 'stop_all; cleanup_lock; exit 143' TERM
trap 'stop_all; cleanup_lock; exit 130' INT
# Runs "$@" as an interruptible child; returns its status.
run_child(){ "$@" & CHILD_PID=$!; wait "$CHILD_PID"; local rc=$?; CHILD_PID=""; return "$rc"; }

# Without Apple's developer tools, /usr/bin/git is a stub that pops Apple's install dialog.
# This runs from launchd, so it must never reach git then: skip the cycle and let a person
# run setup, which can start the install. (Same probe as xcode_clt_ready in lib/common.sh.)
_clt=$(xcode-select -p 2>/dev/null) && [ -d "$_clt" ] || { log "self-update: Apple developer tools missing, cycle skipped"; exit 0; }

if [ ! -d "$ENGINE/.git" ]; then
  run_child git clone --quiet "$REMOTE" "$ENGINE" >/dev/null 2>&1 || { log "self-update: initial clone failed"; exit 0; }
fi

cd "$ENGINE" || exit 0
# The last commit that passed the selfcheck. Remembered in $STATE, not read off HEAD: a run stopped
# between `reset --hard` and the end of the selfcheck (now likely - Fix sends kickstart -k) leaves
# HEAD on an unchecked commit that would then look current forever. No record yet (a Mac before
# this shipped): today's HEAD is taken as verified, exactly as before.
VERIFIED_FILE="$STATE/engine-verified"
prev=$(cat "$VERIFIED_FILE" 2>/dev/null || git rev-parse HEAD 2>/dev/null || echo "")
if run_child git fetch --quiet origin main 2>/dev/null; then
  new=$(git rev-parse origin/main 2>/dev/null || echo "")
  head=$(git rev-parse HEAD 2>/dev/null || echo "")
  if [ -n "$new" ] && { [ "$new" != "$prev" ] || [ "$head" != "$prev" ]; }; then
    git reset --quiet --hard origin/main
    if bash -n sync.sh lib/*.sh 2>>"$LOG" && run_child bash sync.sh --selfcheck 2>>"$LOG"; then
      printf '%s\n' "$new" > "$VERIFIED_FILE"
      [ "$new" != "$prev" ] && log "self-update: updated ${prev:-none} -> $new"
    else
      log "self-update: $new failed selfcheck, restoring ${prev:-none}"
      [ -n "$prev" ] && git reset --quiet --hard "$prev" && git clean -ffdqx
    fi
  elif [ -n "$prev" ] && [ ! -s "$VERIFIED_FILE" ]; then
    printf '%s\n' "$prev" > "$VERIFIED_FILE"
  fi
fi

[ "${1:-}" = "--selfcheck-only" ] && exit 0

# The cycle, with a watchdog: one still running after CYCLE_TIMEOUT_SECONDS is stopped with
# everything it started (a dead network call once held a Mac for 51 minutes, and launchd never
# starts a run while one is alive). Below LOCK_STALE_SECONDS, so the lock is always released by
# its owner, never broken as stale.
CYCLE_TIMEOUT_SECONDS="${CYCLE_TIMEOUT_SECONDS:-1200}"
BRAIN_SYNC_LOCK_HELD=1 bash "$ENGINE/sync.sh" &
CHILD_PID=$!
# A subshell resets the traps above, so the watchdog never touches the lock itself.
(
  waited=0
  while kill -0 "$CHILD_PID" 2>/dev/null; do
    sleep 1; waited=$((waited + 1))
    if [ "$waited" -ge "$CYCLE_TIMEOUT_SECONDS" ]; then
      log "stopped a sync cycle still running after $CYCLE_TIMEOUT_SECONDS s"
      stop_tree "$CHILD_PID"
      exit 0
    fi
  done
) &
WATCH_PID=$!
wait "$CHILD_PID"; rc=$?
# Not killed: if it fired, it is finishing its KILL pass; otherwise it ends within a second.
wait "$WATCH_PID" 2>/dev/null
exit "$rc"
