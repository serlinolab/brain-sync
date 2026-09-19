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
PERSON="${BRAIN_PERSON:-}"
if [ -z "$PERSON" ]; then
  if [ -t 1 ]; then
    read -r -p "Your name (used for your personal repo): " PERSON < /dev/tty 2>/dev/null || PERSON=""
  else
    echo "No terminal is available. Set BRAIN_PERSON and run setup again." >&2
    exit 1
  fi
fi
PERSON_SLUG=$(echo "$PERSON" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')
[ -n "$PERSON_SLUG" ] || { echo "No name was provided. Set BRAIN_PERSON and run setup again." >&2; exit 1; }
printf '%s\n' "$PERSON_SLUG" > "$STATE/person"   # the engine authors commits as this person
echo "Fetching the sync engine..."
setup_ok=1
if [ -d "$ENGINE/.git" ]; then
  git -C "$ENGINE" pull --quiet origin main || { echo "Sync engine update pending." >&2; setup_ok=0; }
elif [ -e "$ENGINE" ]; then
  echo "Sync engine destination exists but is not a usable git repo: $ENGINE" >&2
  setup_ok=0
else
  git clone --quiet "$BRAIN_SYNC_REMOTE" "$ENGINE" || { echo "Could not reach brain-sync. Check your internet connection and try again." >&2; setup_ok=0; }
fi
echo "Generating your keys (they never leave this Mac)..."
if [ ! -f "$MIRROR_KEY" ] || [ ! -f "$MIRROR_KEY.pub" ]; then
  rm -f "$MIRROR_KEY" "$MIRROR_KEY.pub"
  ssh-keygen -t ed25519 -N "" -C "brain-mirror-$(hostname -s)" -f "$MIRROR_KEY" -q || setup_ok=0
fi
if [ ! -f "$PERSONAL_KEY" ] || [ ! -f "$PERSONAL_KEY.pub" ]; then
  rm -f "$PERSONAL_KEY" "$PERSONAL_KEY.pub"
  ssh-keygen -t ed25519 -N "" -C "brain-personal-$PERSON_SLUG" -f "$PERSONAL_KEY" -q || setup_ok=0
fi

append_host() {
  local alias="$1" key="$2"
  grep -q "^Host $alias$" "$SSH_CONFIG" 2>/dev/null && return 0
  if [ -s "$SSH_CONFIG" ] && [ "$(tail -c 1 "$SSH_CONFIG" | wc -l)" -eq 0 ]; then
    printf '\n' >> "$SSH_CONFIG"
  fi
  printf 'Host %s\n  HostName github.com\n  User git\n  IdentityFile %s\n  IdentitiesOnly yes\n' "$alias" "$key" >> "$SSH_CONFIG"
}
append_host brain-mirror "$MIRROR_KEY" || setup_ok=0
append_host brain-personal "$PERSONAL_KEY" || setup_ok=0
chmod 600 "$SSH_CONFIG" || setup_ok=0
mkdir -p "$ROOT/personal" "$ROOT/team"
chmod a-w "$ROOT/team" 2>/dev/null || true   # AC-8: read-only beside the mirror
echo "Cloning the company mirror..."
if [ -e "$ROOT/serlinolab" ]; then
  git -C "$ROOT/serlinolab" rev-parse --git-dir >/dev/null 2>&1 || { echo "Mirror destination is not a usable git repo; clone pending." >&2; setup_ok=0; }
else
  git clone --quiet git@brain-mirror:serlinolab/Serlinolab-Brain.git "$ROOT/serlinolab" || { echo "Mirror clone pending - it will complete once Max has registered your key." >&2; setup_ok=0; }
fi
echo "Cloning your personal notes repo..."
if [ -e "$ROOT/personal/shared" ]; then
  git -C "$ROOT/personal/shared" rev-parse --git-dir >/dev/null 2>&1 || { echo "Personal destination is not a usable git repo; clone pending." >&2; setup_ok=0; }
else
  git clone --quiet "git@brain-personal:serlinolab/brain-personal-$PERSON_SLUG.git" "$ROOT/personal/shared" || { echo "Personal repo clone pending - it will complete once Max has created it." >&2; setup_ok=0; }
fi
echo "Installing the background sync job..."
if [ -f "$ENGINE/lib/launcher.sh" ]; then
  install -m 0755 "$ENGINE/lib/launcher.sh" "$STATE/launcher.sh" || setup_ok=0
else
  echo "Background sync pending: sync engine is not installed." >&2
  setup_ok=0
fi
PLIST_LABEL="com.serlinolab.brainsync"; PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict>' \
  '<key>Label</key><string>com.serlinolab.brainsync</string>' \
  '<key>ProgramArguments</key><array><string>/bin/bash</string><string>'"$STATE/launcher.sh"'</string></array>' \
  '<key>StartInterval</key><integer>300</integer>' \
  '<key>WatchPaths</key><array><string>'"$ROOT/personal/shared"'</string></array>' \
  '<key>StandardOutPath</key><string>'"$STATE/sync.log"'</string>' \
  '<key>StandardErrorPath</key><string>'"$STATE/sync.log"'</string>' \
  '<key>RunAtLoad</key><true/></dict></plist>' > "$PLIST_DEST" || setup_ok=0
if command -v launchctl >/dev/null 2>&1 && launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST" >/dev/null 2>&1 && launchctl kickstart -k "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1; then
  :
else
  echo "launchctl is not installed or could not load the sync job; setup is pending." >&2
  setup_ok=0
fi
if [ "$setup_ok" -eq 1 ]; then
  date -u +%FT%TZ > "$DONE_MARK"
  echo "Setup complete."
else
  rm -f "$DONE_MARK"
  echo "Setup is incomplete; run it again after the pending steps are ready." >&2
fi
echo "SERLINO-BRAIN-SETUP person=$PERSON_SLUG mirror_key=$(cat "$MIRROR_KEY.pub" 2>/dev/null || true) personal_key=$(cat "$PERSONAL_KEY.pub" 2>/dev/null || true)"
[ "$setup_ok" -eq 1 ]
