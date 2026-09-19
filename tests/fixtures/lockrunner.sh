#!/bin/bash
# Test fixture: acquires the lock, holds it briefly, releases on exit.
# Isolates AC-4's locking behaviour from the rest of the sync cycle.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$DIR/lib/common.sh"
acquire_lock || exit 1
sleep "${1:-0.3}"
exit 0
