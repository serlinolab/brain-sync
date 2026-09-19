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

if ! mkdir "$STATE/run.lock" 2>/dev/null; then
  log "self-update: another cycle is running"
  exit 0
fi
echo $$ > "$STATE/run.lock/pid"
trap 'rm -rf "$STATE/run.lock"' EXIT INT TERM

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
      [ -n "$prev" ] && git reset --quiet --hard "$prev"
    fi
  fi
fi

[ "${1:-}" = "--selfcheck-only" ] && exit 0
BRAIN_SYNC_LOCK_HELD=1 bash "$ENGINE/sync.sh"
