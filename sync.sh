#!/bin/bash
# Serlino Brain sync engine. Invoked by lib/launcher.sh (see there for why
# launchd never calls this file directly).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
source "$DIR/lib/sync.sh"

# Self-update's smoke test: proves this copy sources cleanly and can run,
# without touching the lock, network, or any repo.
[ "${1:-}" = "--selfcheck" ] && exit 0

acquire_lock || exit 0
commit_local          # AC-3: local restore point before any network call
stale_check           # AC-6: local-only, evaluated before the network step
if ! online; then
  log "offline; local work is committed, nothing more to do this cycle"
  exit 0
fi
sync_mirror
sync_personal
what_changed
