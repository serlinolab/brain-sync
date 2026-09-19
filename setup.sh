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
setup_ok=1
if [ ! -e "$STATE/person" ]; then
  printf '%s\n' "$PERSON_SLUG" > "$STATE/person"   # the engine authors commits as this person
elif [ "$(cat "$STATE/person" 2>/dev/null)" != "$PERSON_SLUG" ]; then
  echo "Person mismatch at $STATE/person: found '$(cat "$STATE/person" 2>/dev/null)', requested '$PERSON_SLUG'." >&2
  exit 1
fi
echo "Fetching the sync engine..."
if [ -d "$ENGINE/.git" ]; then
  git -C "$ENGINE" pull --quiet origin main || { echo "Sync engine update pending." >&2; setup_ok=0; }
elif [ -e "$ENGINE" ]; then
  echo "Sync engine destination exists but is not a usable git repo: $ENGINE" >&2
  setup_ok=0
else
  git clone --quiet "$BRAIN_SYNC_REMOTE" "$ENGINE" || { echo "Could not reach brain-sync. Check your internet connection and try again." >&2; setup_ok=0; }
fi
echo "Generating your keys (they never leave this Mac)..."
derive_public_key() {
  local key="$1" pub="$1.pub" tmp
  tmp=$(mktemp "$pub.tmp.XXXXXX") || return 1
  if ssh-keygen -y -f "$key" > "$tmp" && [ -s "$tmp" ]; then
    mv -f "$tmp" "$pub"
  else
    rm -f "$tmp"
    return 1
  fi
}
if [ ! -f "$MIRROR_KEY" ]; then
  ssh-keygen -t ed25519 -N "" -C "brain-mirror-$(hostname -s)" -f "$MIRROR_KEY" -q || setup_ok=0
elif [ ! -s "$MIRROR_KEY.pub" ]; then
  derive_public_key "$MIRROR_KEY" || setup_ok=0
fi
if [ ! -f "$PERSONAL_KEY" ]; then
  ssh-keygen -t ed25519 -N "" -C "brain-personal-$PERSON_SLUG" -f "$PERSONAL_KEY" -q || setup_ok=0
elif [ ! -s "$PERSONAL_KEY.pub" ]; then
  derive_public_key "$PERSONAL_KEY" || setup_ok=0
fi

append_host() {
  local alias="$1" key="$2"
  grep -q "^Host $alias$" "$SSH_CONFIG" 2>/dev/null && return 0
  if [ -s "$SSH_CONFIG" ] && [ "$(tail -c 1 "$SSH_CONFIG" | wc -l)" -eq 0 ]; then
    printf '\n' >> "$SSH_CONFIG"
  fi
  printf 'Host %s\n  HostName github.com\n  User git\n  IdentityFile "%s"\n  IdentitiesOnly yes\n' "$alias" "$key" >> "$SSH_CONFIG"
}
append_host brain-mirror "$MIRROR_KEY" || setup_ok=0
append_host brain-personal "$PERSONAL_KEY" || setup_ok=0
chmod 600 "$SSH_CONFIG" || setup_ok=0
mkdir -p "$ROOT/personal" "$ROOT/team"
chmod a-w "$ROOT/team" 2>/dev/null || true   # AC-8: read-only beside the mirror
echo "Cloning the company mirror..."
remote_matches() {
  local path="$1" expected="$2" url
  [ -d "$path/.git" ] || return 1
  [ "$(git -C "$path" remote get-url origin 2>/dev/null || true)" = "$expected" ] || return 1
  while IFS= read -r url; do
    [ "$url" = "$expected" ] || return 1
  done < <(git -C "$path" remote get-url --push --all origin 2>/dev/null)
}
expected_mirror='git@brain-mirror:serlinolab/Serlinolab-Brain.git'
if [ -e "$ROOT/serlinolab" ]; then
  actual=$(git -C "$ROOT/serlinolab" remote get-url origin 2>/dev/null || echo '<missing origin>')
  if ! remote_matches "$ROOT/serlinolab" "$expected_mirror"; then
    echo "Refusing to adopt $ROOT/serlinolab: origin is $actual, expected $expected_mirror (including push URLs)." >&2
    setup_ok=0
  fi
else
  git clone --quiet "$expected_mirror" "$ROOT/serlinolab" || { echo "Mirror clone pending - it will complete once Max has registered your key." >&2; setup_ok=0; }
fi
echo "Cloning your personal notes repo..."
expected_personal="git@brain-personal:serlinolab/brain-personal-$PERSON_SLUG.git"
if [ -e "$ROOT/personal/shared" ]; then
  actual=$(git -C "$ROOT/personal/shared" remote get-url origin 2>/dev/null || echo '<missing origin>')
  if ! remote_matches "$ROOT/personal/shared" "$expected_personal"; then
    echo "Refusing to adopt $ROOT/personal/shared: origin is $actual, expected $expected_personal (including push URLs)." >&2
    setup_ok=0
  fi
else
  git clone --quiet "$expected_personal" "$ROOT/personal/shared" || { echo "Personal repo clone pending - it will complete once Max has created it." >&2; setup_ok=0; }
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
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
STATE_XML=$(xml_escape "$STATE"); ROOT_XML=$(xml_escape "$ROOT")
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict>' \
  '<key>Label</key><string>com.serlinolab.brainsync</string>' \
  '<key>ProgramArguments</key><array><string>/bin/bash</string><string>'"$STATE_XML/launcher.sh"'</string></array>' \
  '<key>StartInterval</key><integer>300</integer>' \
  '<key>WatchPaths</key><array><string>'"$ROOT_XML/personal/shared"'</string></array>' \
  '<key>StandardOutPath</key><string>'"$STATE_XML/sync.log"'</string>' \
  '<key>StandardErrorPath</key><string>'"$STATE_XML/sync.log"'</string>' \
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
