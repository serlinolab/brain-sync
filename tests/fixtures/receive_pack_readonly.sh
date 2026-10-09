#!/bin/bash
# Test fixture: stands in for git-receive-pack on a Brain clone whose deploy key is read-only
# (set as remote.origin.receivepack). Prints what GitHub prints and refuses, which is all the
# engine's write probe (lib/brain_write.sh, brain_probe_push) looks at.
echo "ERROR: The key you are authenticating with has been marked as read only." >&2
exit 1
