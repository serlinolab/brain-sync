#!/bin/bash
# Serlino Brain - one-time Mac setup. Paste-and-run:
#   curl -fsSL https://raw.githubusercontent.com/serlinolab/brain-sync/main/setup.sh | bash
set -u
ROOT="$HOME/Serlino"; STATE="$ROOT/.state"; ENGINE="$STATE/engine"
DONE_MARK="$STATE/setup-complete"
BRAIN_SYNC_REMOTE="${BRAIN_SYNC_REMOTE:-https://github.com/serlinolab/brain-sync.git}"
MIRROR_KEY="$HOME/.ssh/brain_mirror_ed25519"
PERSONAL_KEY="$HOME/.ssh/brain_personal_ed25519"
SSH_CONFIG="$HOME/.ssh/config"
mkdir -p "$STATE" "$HOME/.ssh"
if [ -f "$DONE_MARK" ]; then echo "Already set up on this Mac. Nothing changed."; exit 0; fi
read -r -p "Your name (used for your personal repo): " PERSON
PERSON_SLUG=$(echo "$PERSON" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')
[ -n "$PERSON_SLUG" ] || { echo "A name is needed to continue." >&2; exit 1; }
echo "Fetching the sync engine..."
if [ -d "$ENGINE/.git" ]; then
  git -C "$ENGINE" pull --quiet origin main || true
else
  git clone --quiet "$BRAIN_SYNC_REMOTE" "$ENGINE" || { echo "Could not reach brain-sync. Check your internet connection and try again." >&2; exit 1; }
fi
echo "Generating your keys (they never leave this Mac)..."
[ -f "$MIRROR_KEY" ] || ssh-keygen -t ed25519 -N "" -C "brain-mirror-$(hostname -s)" -f "$MIRROR_KEY" -q
[ -f "$PERSONAL_KEY" ] || ssh-keygen -t ed25519 -N "" -C "brain-personal-$PERSON_SLUG" -f "$PERSONAL_KEY" -q
if ! grep -q "^Host brain-mirror$" "$SSH_CONFIG" 2>/dev/null; then
  printf 'Host brain-mirror\n  HostName github.com\n  User git\n  IdentityFile %s\n  IdentitiesOnly yes\nHost brain-personal\n  HostName github.com\n  User git\n  IdentityFile %s\n  IdentitiesOnly yes\n' \
    "$MIRROR_KEY" "$PERSONAL_KEY" >> "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
fi
mkdir -p "$ROOT/personal/shared" "$ROOT/team"
chmod a-w "$ROOT/team" 2>/dev/null || true   # AC-8: read-only beside the mirror
echo "Cloning the company mirror..."
[ -d "$ROOT/serlinolab/.git" ] || git clone --quiet git@brain-mirror:serlinolab/Serlinolab-Brain.git "$ROOT/serlinolab" \
  || echo "Mirror clone pending - it will complete once Max has registered your key."
echo "Cloning your personal notes repo..."
[ -d "$ROOT/personal/shared/.git" ] || git clone --quiet "git@brain-personal:serlinolab/brain-personal-$PERSON_SLUG.git" "$ROOT/personal/shared" \
  || echo "Personal repo clone pending - it will complete once Max has created it."
echo "Installing the background sync job..."
install -m 0755 "$ENGINE/lib/launcher.sh" "$STATE/launcher.sh"
PLIST_LABEL="com.serlinolab.brainsync"; PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s#__LAUNCHER__#$STATE/launcher.sh#g" -e "s#__WATCH_PATH__#$ROOT/personal/shared#g" -e "s#__LOG__#$STATE/sync.log#g" \
    "$ENGINE/launchd/$PLIST_LABEL.plist" > "$PLIST_DEST"
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || launchctl load -w "$PLIST_DEST" 2>/dev/null || true
launchctl kickstart -k "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
date -u +%FT%TZ > "$DONE_MARK"
echo "Setup complete."
echo "SERLINO-BRAIN-SETUP person=$PERSON_SLUG mirror_key=$(cat "$MIRROR_KEY.pub") personal_key=$(cat "$PERSONAL_KEY.pub")"
