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
# Test-only hooks, both no-ops unless a test sets the env var. SYNC_HOLD_SECONDS (unchanged,
# still used by tests/fixtures/lockrunner.sh and tests/single_instance.bats) holds the lock for
# a fixed guessed duration. MAX-1515 re-review, finding F5: the signal-file pair below replaces
# that guess for tests/setup.bats's own concurrency test - a holder announces "I actually hold
# the lock now" by creating SYNC_HOLD_READY_FILE, and waits for the test to say "you can let go
# now" via SYNC_HOLD_RELEASE_FILE, so the two processes rendezvous on real state instead of on
# how long a sleep the test author guessed would be enough.
[ -n "${SYNC_HOLD_READY_FILE:-}" ] && : > "$SYNC_HOLD_READY_FILE"
if [ -n "${SYNC_HOLD_RELEASE_FILE:-}" ]; then
  while [ ! -e "$SYNC_HOLD_RELEASE_FILE" ]; do sleep 0.02; done
fi
[ -n "${SYNC_HOLD_SECONDS:-}" ] && sleep "$SYNC_HOLD_SECONDS"
person_warn
# MAX-1515 change A, amended by review finding B: finish a pending setup (the deploy key may
# just have been registered) before doing anything else this cycle. Never trusts
# $STATE/team-configured or $STATE/setup-complete as proof team/ or Serlinolab_Brain/ are actually
# ready - both can survive a replacement directory that was never reconfigured.
# team_is_protected/mirror_is_ready (lib/complete_setup.sh) re-derive the real state instead,
# every cycle, so a finished Mac's cycles skip the call below without ever trusting a marker.
# A still-pending or still-misconfigured mirror is never fatal to the rest of the cycle - it is
# synced below exactly as it is today, independent of team/.
#
# MAX-1515 re-review, finding F1b: complete_setup's own status THIS cycle used to be discarded
# outright (`complete_setup || true`), letting the cycle fall straight through to
# commit_local/sync_team regardless of what happened. Kept in a variable instead ($setup_rc,
# read by commit_local/sync_team themselves - lib/sync.sh - so it gates them from the inside
# without wrapping their call sites here: AC-3's own regression test greps sync.sh for
# `commit_local` as a bare top-level line to prove no network call precedes it, and a
# conditional call site would have broken that proof for no real gain). Gated ONLY on exit 3,
# not on "any non-zero": pending (1) and refused (2) leave team/ exactly as safe to check as it
# always was - if team/ exists at all in those cases its origin already fails
# commit_local/sync_team's own remote_matches_expected pre-check, which is what makes them
# refuse (and this cycle exit non-zero) on their own, same as before this finding. Exit 3 is
# different in kind: THIS cycle's own reconfigure attempt wrote real config into team/
# (hooksPath, symlinks, sparse-checkout state, hooks) and then failed partway - exactly the
# state finding F1a closes a blind spot in (team_is_protected's own re-check inside
# commit_local/sync_team is a genuine second layer now, not a reason to trust this status
# less). Only for exit 3 is that status the one thing standing between this cycle and treating
# a half-configured team/ as fine.
if team_is_protected && mirror_is_ready; then
  setup_rc=0
else
  complete_setup
  setup_rc=$?
fi
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
