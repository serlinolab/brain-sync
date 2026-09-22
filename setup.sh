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

remote_matches() {
  local path="$1" expected="$2" url
  [ -d "$path/.git" ] || return 1
  [ "$(git -C "$path" remote get-url origin 2>/dev/null || true)" = "$expected" ] || return 1
  while IFS= read -r url; do
    [ "$url" = "$expected" ] || return 1
  done < <(git -C "$path" remote get-url --push --all origin 2>/dev/null)
}

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

echo "Setting up the team folder..."
expected_team='git@brain-team:serlinolab/brain-team.git'
team_ready=0
if [ -e "$ROOT/team" ]; then
  actual=$(git -C "$ROOT/team" remote get-url origin 2>/dev/null || echo '<missing origin>')
  if remote_matches "$ROOT/team" "$expected_team"; then
    team_ready=1
  else
    echo "Refusing to adopt $ROOT/team: origin is $actual, expected $expected_team (including push URLs)." >&2
    setup_ok=0
  fi
else
  if git clone --quiet "$expected_team" "$ROOT/team"; then
    team_ready=1   # a fresh clone is trusted without re-checking remote_matches: a test
                    # double that rewrites the URL argument would make a freshly cloned
                    # origin fail a literal-string re-check even though the clone is correct
  else
    echo "Team folder clone pending - it will complete once Max has registered your key." >&2
    setup_ok=0
  fi
fi

TEAM="$ROOT/team"
if [ "$team_ready" -eq 1 ]; then
  echo "Configuring the team folder so it can never carry instruction files..."
  # AC-4 structural layer: a colleague's CLAUDE.md/.claude never checks out here, at any
  # depth, regardless of whether they committed it as a file, a directory or a symlink.
  # Verified (2026-09-22): non-cone patterns without a leading slash match at every depth on
  # this git, so no **/ forms are needed. Shared with tests/helpers.bash via
  # lib/team_layout.sh so the two can never drift apart.
  # shellcheck source=lib/team_layout.sh
  source "$ENGINE/lib/team_layout.sh" || setup_ok=0
  write_team_sparse_checkout "$TEAM" || setup_ok=0

  echo "Installing the secret-scan hooks..."
  # shellcheck source=lib/secretscan.sh
  source "$ENGINE/lib/secretscan.sh" || setup_ok=0
  install_team_hooks "$TEAM" "$STATE/engine/lib" || setup_ok=0

  echo "Cloning the company mirror..."
  expected_mirror='git@brain-mirror:serlinolab/Serlinolab-Brain.git'
  MIRROR="$ROOT/serlinolab"
  if [ -e "$MIRROR" ]; then
    actual=$(git -C "$MIRROR" remote get-url origin 2>/dev/null || echo '<missing origin>')
    if ! remote_matches "$MIRROR" "$expected_mirror"; then
      echo "Refusing to adopt $MIRROR: origin is $actual, expected $expected_mirror (including push URLs)." >&2
      setup_ok=0
    fi
  else
    git clone --quiet "$expected_mirror" "$MIRROR" || { echo "Mirror clone pending - it will complete once Max has registered your key." >&2; setup_ok=0; }
  fi
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
  echo "Setup is incomplete; run it again after the pending steps are ready." >&2
fi
echo "SERLINO-BRAIN-SETUP person=$PERSON_SLUG machine=$(hostname -s) mirror_key=$(cat "$MIRROR_KEY.pub" 2>/dev/null || true) team_key=$(cat "$TEAM_KEY.pub" 2>/dev/null || true)"
[ "$setup_ok" -eq 1 ]
