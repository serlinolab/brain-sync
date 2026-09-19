#!/bin/bash
# Test fixture: runs the real sync entry point and holds its real lock.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYNC_HOLD_SECONDS="${1:-0.3}" bash "$DIR/sync.sh"
