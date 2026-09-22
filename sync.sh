#!/bin/bash
# Serlino Brain sync engine. Invoked by lib/launcher.sh (see there for why
# launchd never calls this file directly).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
source "$DIR/lib/secretscan.sh"
source "$DIR/lib/sync.sh"

# Self-update's smoke test: proves this copy sources cleanly and can run,
# without touching the lock, network, or any repo.
[ "${1:-}" = "--selfcheck" ] && exit 0

if [ "${BRAIN_SYNC_LOCK_HELD:-0}" != 1 ]; then acquire_lock || exit 0; fi
[ -n "${SYNC_HOLD_SECONDS:-}" ] && sleep "$SYNC_HOLD_SECONDS"
person_warn
commit_local
commit_rc=$?
if [ "$commit_rc" -eq 1 ]; then
  log "local commit failed; stopping before network"
  update_attention_marker
  exit 1
fi
stale_check
if ! online; then
  log "offline; local work is committed, nothing more to do this cycle"
  update_attention_marker
  exit 0
fi
sync_mirror
cycle_rc=$?
sync_team || cycle_rc=$?
what_changed
update_attention_marker
exit "$cycle_rc"
