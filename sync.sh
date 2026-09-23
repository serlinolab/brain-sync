#!/bin/bash
# Serlino Brain sync engine. Invoked by lib/launcher.sh (see there for why
# launchd never calls this file directly).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
source "$DIR/lib/secretscan.sh"
source "$DIR/lib/team_layout.sh"
source "$DIR/lib/complete_setup.sh"
source "$DIR/lib/sync.sh"

# Self-update's smoke test: proves this copy sources cleanly and can run,
# without touching the lock, network, or any repo.
[ "${1:-}" = "--selfcheck" ] && exit 0

if [ "${BRAIN_SYNC_LOCK_HELD:-0}" != 1 ]; then acquire_lock || exit 0; fi
[ -n "${SYNC_HOLD_SECONDS:-}" ] && sleep "$SYNC_HOLD_SECONDS"
person_warn
# MAX-1515 change A, amended by review finding B: finish a pending setup (the deploy key may
# just have been registered) before doing anything else this cycle. Never trusts
# $STATE/team-configured or $STATE/setup-complete as proof team/ or serlinolab/ are actually
# ready - both can survive a replacement directory that was never reconfigured.
# team_is_protected/mirror_is_ready (lib/complete_setup.sh) re-derive the real state instead,
# every cycle, so a finished Mac's cycles skip the call below without ever trusting a marker.
# A still-pending or still-misconfigured result is never fatal to the rest of the cycle:
# whatever already exists on disk is synced below exactly as it is today, and
# commit_local/sync_team check their own readiness again in a moment.
team_is_protected && mirror_is_ready || complete_setup || true
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
