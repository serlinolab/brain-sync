#!/bin/bash
# Serlino Brain - one-time Mac setup. Paste-and-run:
#   curl -fsSL https://raw.githubusercontent.com/serlinolab/brain-sync/main/setup.sh | bash
set -u
ROOT="$HOME/Serlino"; STATE="$ROOT/.state"; ENGINE="$STATE/engine"
DONE_MARK="$STATE/setup-complete"
LAYOUT_MARK="$STATE/layout"
BRAIN_SYNC_REMOTE="${BRAIN_SYNC_REMOTE:-https://github.com/serlinolab/brain-sync.git}"
MIRROR_KEY="$HOME/.ssh/brain_mirror_ed25519"
TEAM_KEY="$HOME/.ssh/brain_team_ed25519"
SSH_CONFIG="$HOME/.ssh/config"

# AC-8: refuse BEFORE any mutation when $ROOT exists but was not built by this setup - the
# MAX-1514 layout (had .state/setup-complete, never wrote .state/layout), the earlier
# parker-v1 nested layout (nobody has installed it, so no migration is needed - it is refused
# the same as any other stranger), and any hand-made folder all fail this the same way. A read
# (`cat`) never mutates, so this check is safe to run before mkdir touches anything.
if [ -e "$ROOT" ]; then
  existing_layout=$(cat "$LAYOUT_MARK" 2>/dev/null || true)
  if [ "$existing_layout" != "parker-v2" ]; then
    echo "A Serlino folder already exists on this Mac and was not made by this setup. Nothing was changed. Please tell Max." >&2
    exit 1
  fi
fi

mkdir -p "$STATE" "$HOME/.ssh"
printf 'parker-v2\n' > "$LAYOUT_MARK"
# Recorded once - used to raise "SOMETHING NEEDS YOUR ATTENTION.txt" if setup is still pending
# after SETUP_PENDING_ALERT_HOURS (lib/sync.sh's update_attention_marker).
[ -f "$STATE/setup-started" ] || date +%s > "$STATE/setup-started"

PERSON="${BRAIN_PERSON:-}"
if [ -z "$PERSON" ]; then
  if [ -t 1 ]; then
    read -r -p "Your name (used to credit your notes): " PERSON < /dev/tty 2>/dev/null || PERSON=""
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
TEMPLATES="$ENGINE/templates"

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
if [ ! -f "$TEAM_KEY" ]; then
  ssh-keygen -t ed25519 -N "" -C "brain-team-$(hostname -s)" -f "$TEAM_KEY" -q || setup_ok=0
elif [ ! -s "$TEAM_KEY.pub" ]; then
  derive_public_key "$TEAM_KEY" || setup_ok=0
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
append_host brain-team "$TEAM_KEY" || setup_ok=0
chmod 600 "$SSH_CONFIG" || setup_ok=0

write_if_absent() {   # $1=dest $2=template basename under templates/ - never overwrites a person's files
  [ -e "$1" ] && return 0
  local tmpl="$TEMPLATES/$2"
  mkdir -p "$(dirname "$1")"
  if [ -f "$tmpl" ]; then cp "$tmpl" "$1"; else : > "$1"; fi
}

echo "Writing the signpost..."
if [ -f "$TEMPLATES/signpost.md" ]; then
  cp "$TEMPLATES/signpost.md" "$ROOT/CLAUDE.md" || setup_ok=0
else
  : > "$ROOT/CLAUDE.md"
fi
if [ -L "$ROOT/AGENTS.md" ] && [ "$(readlink "$ROOT/AGENTS.md")" = "CLAUDE.md" ]; then
  :
else
  rm -f "$ROOT/AGENTS.md"
  ln -s CLAUDE.md "$ROOT/AGENTS.md" || setup_ok=0
fi

echo "Setting up your personal folders..."
mkdir -p "$ROOT/personal/brands" "$ROOT/personal/ideas" "$ROOT/personal/finds"
write_if_absent "$ROOT/personal/README.md" personal-README.md
write_if_absent "$ROOT/personal/brands/README.md" personal-brands-README.md
write_if_absent "$ROOT/personal/ideas/README.md" personal-ideas-README.md
write_if_absent "$ROOT/personal/finds/README.md" personal-finds-README.md

TEAM="$ROOT/team"
echo "Setting up the team folder and the company mirror..."
# shellcheck source=lib/complete_setup.sh
source "$ENGINE/lib/complete_setup.sh" || { echo "Sync engine is missing lib/complete_setup.sh." >&2; exit 1; }
# MAX-1515 review finding A: a background sync cycle (lib/sync.sh) calls complete_setup too,
# holding this same lock for its whole run. Without taking it here as well, this run and a
# background cycle could execute complete_setup at the same moment - the failed-clone cleanup
# that follows a lost race would then delete whichever side actually finished (see
# lib/complete_setup.sh's own defence for the deeper story). Taking the one lock every caller
# shares makes that structurally impossible instead of merely unlikely.
# shellcheck source=lib/common.sh
source "$ENGINE/lib/common.sh" || { echo "Sync engine is missing lib/common.sh." >&2; exit 1; }
# common.sh re-derives ROOT from $BRAIN_ROOT (a sync-cycle override this script never accepts -
# setup.sh's folder is always $HOME/Serlino) and STATE/TEAM/PERSON_SLUG from that, which would
# silently point acquire_lock's own lock, and complete_setup's own targets, at the wrong place
# (and re-derive the wrong person) whenever $BRAIN_ROOT happens to be set in the environment
# for something else entirely. Restore this script's own values immediately - the ONE thing
# this source is for is acquire_lock/cleanup_lock.
ROOT="$HOME/Serlino"; STATE="$ROOT/.state"; LOCK="$STATE/run.lock"; TEAM="$ROOT/team"
PERSON_SLUG="$(cat "$STATE/person" 2>/dev/null || true)"
complete_setup_rc=1
if acquire_lock; then
  complete_setup; complete_setup_rc=$?
  cleanup_lock
else
  echo "Setup is already being completed in the background - waiting briefly for it to finish..." >&2
  sleep 2
  if acquire_lock; then
    complete_setup; complete_setup_rc=$?
    cleanup_lock
  else
    echo "Setup is still being completed in the background. Nothing more to do here right now." >&2
  fi
fi
case $complete_setup_rc in
  0) : ;;   # fully done this run (or already was)
  1) setup_ok=0 ;;   # a clone could not connect yet (key not registered), or the lock was held
                      # by a concurrent run - fall through to the background-job install below;
                      # any message from complete_setup itself was already printed
  2)
    # MAX-1515 fix 4a: exit immediately - never fall through to the launchd install below
    # against a folder this run just refused to touch. complete_setup already printed the
    # refusal message.
    exit 1
    ;;
  3)
    # MAX-1515 review finding E: this is a configuration failure, not a missing-key "pending"
    # state - nothing here will retry it on its own, so the message must say so plainly instead
    # of implying the folders will still appear by themselves. Never install the background job
    # against a run where the team folder configuration itself failed - complete_setup already
    # removed the half-configured clone.
    setup_ok=0
    rm -f "$DONE_MARK"
    echo "Setup could not finish preparing the team folder. Nothing was lost. Please tell Max." >&2
    exit 1
    ;;
esac

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
STATE_XML=$(xml_escape "$STATE"); TEAM_XML=$(xml_escape "$TEAM")
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict>' \
  '<key>Label</key><string>com.serlinolab.brainsync</string>' \
  '<key>ProgramArguments</key><array><string>/bin/bash</string><string>'"$STATE_XML/launcher.sh"'</string></array>' \
  '<key>StartInterval</key><integer>300</integer>' \
  '<key>WatchPaths</key><array><string>'"$TEAM_XML"'</string></array>' \
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
  echo "Send Max the line starting SERLINO-BRAIN-SETUP. That's all - your folders appear on their own within a few minutes of his approval." >&2
fi
echo "SERLINO-BRAIN-SETUP person=$PERSON_SLUG machine=$(hostname -s) mirror_key=$(cat "$MIRROR_KEY.pub" 2>/dev/null || true) team_key=$(cat "$TEAM_KEY.pub" 2>/dev/null || true)"
[ "$setup_ok" -eq 1 ]
