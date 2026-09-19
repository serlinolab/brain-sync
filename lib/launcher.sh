#!/bin/bash
# AC-9: self-update from THIS repo (brain-sync), never from the Brain, with
# rollback to the last working copy when a new one fails to run. Installed
# by setup.sh outside the engine clone it manages, and self-contained (no
# `source` of engine files) so a broken update can't take down the rollback.
set -u
ROOT="${BRAIN_ROOT:-$HOME/Serlino}"
STATE="$ROOT/.state"; ENGINE="$STATE/engine"; LOG="$STATE/sync.log"
REMOTE="${BRAIN_SYNC_REMOTE:-https://github.com/serlinolab/brain-sync.git}"
mkdir -p "$STATE"
log(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

LOCK="$STATE/run.lock"
acquire_lock(){
  if ! mkdir "$LOCK" 2>/dev/null; then
    if [ -f "$LOCK/pid" ] && ! kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then
      local stale="$LOCK.stale.$$"
      log "self-update: breaking stale lock from pid $(cat "$LOCK/pid")"
      mv "$LOCK" "$stale" 2>/dev/null || return 1
      if ! mkdir "$LOCK" 2>/dev/null; then
        rm -rf "$stale"
        return 1
      fi
      rm -rf "$stale"
    else
      log "self-update: another cycle is running"
      return 1
    fi
  fi
  echo $$ > "$LOCK/pid"
  # shellcheck disable=SC2329  # invoked indirectly by trap
  cleanup_lock(){
    [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"
  }
  trap 'cleanup_lock' EXIT
  trap 'cleanup_lock; exit 130' INT
  trap 'cleanup_lock; exit 143' TERM
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
