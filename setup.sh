#!/bin/bash
# Serlino Brain - one-time Mac setup. Use Max's published commit ID and SHA256:
# setup_dir=$(mktemp -d) && (
#   cd "$setup_dir" &&
#   curl -fsSLo setup.sh 'https://raw.githubusercontent.com/serlinolab/brain-sync/<REVIEWED_COMMIT_ID>/setup.sh' &&
#   printf '%s  setup.sh\n' '<SHA256_PUBLISHED_BY_MAX>' | shasum -a 256 -c - &&
#   bash setup.sh
# )
# An immutable URL plus an independently published checksum protects the installer and its pin.
set -u
ROOT="$HOME/Serlinolab"; STATE="$ROOT/.state"; ENGINE="$STATE/engine"
DONE_MARK="$STATE/setup-complete"
LAYOUT_MARK="$STATE/layout"
BRAIN_SYNC_REMOTE="${BRAIN_SYNC_REMOTE:-https://github.com/serlinolab/brain-sync.git}"
MIRROR_KEY="$HOME/.ssh/brain_mirror_ed25519"
TEAM_KEY="$HOME/.ssh/brain_team_ed25519"
SSH_CONFIG="$HOME/.ssh/config"
CLT_MISSING_EXIT_CODE=42   # distinct from every other exit in this script - see the CLT check below

# AC-8: refuse BEFORE any mutation when $ROOT exists but was not built by this setup - the
# MAX-1514 layout (had .state/setup-complete, never wrote .state/layout), the earlier
# parker-v1 nested layout (nobody has installed it, so no migration is needed - it is refused
# the same as any other stranger), and any hand-made folder all fail this the same way. A read
# (`cat`) never mutates, so this check is safe to run before mkdir touches anything.
if [ -e "$ROOT" ]; then
  existing_layout=$(cat "$LAYOUT_MARK" 2>/dev/null || true)
  if [ "$existing_layout" != "parker-v2" ]; then
    echo "A Serlinolab folder already exists on this Mac and was not made by this setup. Nothing was changed. Please tell Max." >&2
    exit 1
  fi
fi

mkdir -p "$STATE" "$HOME/.ssh"
printf 'parker-v2\n' > "$LAYOUT_MARK"
# Recorded once - used to raise "SOMETHING NEEDS YOUR ATTENTION.txt" if setup is still pending
# after SETUP_PENDING_ALERT_HOURS (lib/sync.sh's update_attention_marker).
[ -f "$STATE/setup-started" ] || date +%s > "$STATE/setup-started"

# On a fresh Mac /usr/bin/git is only a stub until Apple's Command Line Tools (CLT) are
# installed - calling it pops the "install developer tools?" dialog and fails, which is exactly
# what the very next section (cloning the sync engine) would hit with no warning. `xcode-select
# -p` is the one Apple-documented probe that reports CLT presence WITHOUT ever triggering that
# prompt, so it is always safe to call first. A stale path (e.g. a symlink left over after
# Xcode.app was removed) can still make `-p` report success, so once it does we confirm with
# `git --version` - safe to call at that point, since the tools are already confirmed present.
# --- IDENTICAL COPY in setup.sh and lib/common.sh. Duplicated on purpose: this runs before the
# sync engine is cloned, so lib/common.sh is not on disk yet for this script to source.
xcode_clt_ready(){
  local dir
  dir=$(xcode-select -p 2>/dev/null) && [ -d "$dir" ] || return 1
  git --version >/dev/null 2>&1
}
if ! xcode_clt_ready; then
  # Start Apple's install every time: if one is already running, Apple's tool just declines,
  # and if the person cancelled it, this brings the window back instead of getting stuck.
  xcode-select --install >/dev/null 2>&1 || true
  echo "Apple needs to install its developer tools on this Mac - this only happens once, on a new Mac. If a window from Apple is open, click Install and wait for it to finish (a few minutes). Then paste the same setup line again." >&2
  echo "If Apple says the software is \"not currently available from the Software Update server\": open https://developer.apple.com/download/all/ , sign in with your Apple ID, search \"Command Line Tools\", download the newest one for your Mac, open it and install it. Then paste the same setup line again." >&2
  exit "$CLT_MISSING_EXIT_CODE"
fi

PERSON="${BRAIN_PERSON:-}"
if [ -z "$PERSON" ]; then
  if [ -t 1 ]; then
    # `read -p` sends its prompt to stderr, not the terminal it reads from - piped through
    # a piped setup invocation stderr can be silently swallowed, so the
    # prompt never appeared and the terminal looked frozen (hit live by Max). Print the question
    # to /dev/tty ourselves, then read the answer from /dev/tty with no prompt of read's own.
    printf 'Your first name (it signs the notes you share in team/): ' > /dev/tty
    read -r PERSON < /dev/tty || PERSON=""
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

# --- signed trust: identical in setup.sh and lib/launcher.sh; never source from a fetched tree.
# Pin the dedicated release key in BOTH entry points before shipping. No environment override.
# Bootstrap accepts only ssh-ed25519 keys (including both keys during a rotation bridge).
BOOTSTRAP_SIGNER_FINGERPRINT='SHA256:Xg9wI1FYOIN4LfRJgZFfXbyEEBwPcvlFVwhsZgzk6KA'
export GIT_NO_REPLACE_OBJECTS=1
TRUST_DIR="$STATE/update-trust"
SIGNERS="$TRUST_DIR/allowed_signers"
trust_private(){
  [ ! -L "$1" ] && [ -O "$1" ] || return 1
  local mode
  mode=$(stat -f %Lp "$1" 2>/dev/null) || return 1
  [ "$mode" = "$2" ]
}
trust_verify(){
  # Git selects a verifier from the signature header, regardless of gpg.format.
  # Inspect only object headers (never a lookalike in the commit message).
  git -C "$ENGINE" cat-file commit "$2" 2>/dev/null | awk '
    /^$/ { exit }
    /^gpgsig(-sha256)? / {
      found++
      if ($0 !~ /^gpgsig(-sha256)? -----BEGIN SSH SIGNATURE-----$/) bad=1
    }
    END { exit !(found > 0 && !bad) }
  ' || return 1
  git -C "$ENGINE" -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen \
    -c gpg.program=false -c gpg.x509.program=false \
    -c gpg.ssh.allowedSignersFile="$1" -c gpg.ssh.revocationFile=/dev/null \
    verify-commit "$2" >/dev/null 2>&1
}
trust_sha(){
  case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}
trust_anchor(){ sed -n 's/^# signed-anchor: //p' "$SIGNERS"; }
trust_check(){
  trust_private "$TRUST_DIR" 700 && trust_private "$SIGNERS" 600 || return 1
  local anchor; anchor=$(trust_anchor)
  trust_sha "$anchor" && trust_sha "$1" || return 1
  git -C "$ENGINE" merge-base --is-ancestor "$anchor" "$1" || return 1
  trust_verify "$SIGNERS" "$1"
}
trust_write(){
  # Caller has already authenticated this object with the OLD list. Commit + list are one
  # atomic file, so interruption cannot lower the anchor or leave a half-written rotation.
  local sha="$1" list="$2" tmp
  tmp=$(mktemp "$TRUST_DIR/.signers.XXXXXX") || return 1
  { printf '# signed-anchor: %s\n' "$sha"; sed '/^# signed-anchor:/d' "$list"; } > "$tmp" &&
    chmod 600 "$tmp" && mv -f "$tmp" "$SIGNERS" && return 0
  rm -f "$tmp"; return 1
}
trust_bootstrap(){
  local sha="$1" tmp pub fingerprint count keys
  # An existing directory, even broken/empty, is NEVER permission to re-pin from the repo.
  if [ -e "$TRUST_DIR" ] || [ -L "$TRUST_DIR" ]; then trust_check "$sha"; return; fi
  trust_sha "$sha" || return 1
  tmp=$(mktemp -d "$STATE/.trust-bootstrap.XXXXXX") || return 1
  git -C "$ENGINE" show "$sha:config/allowed_signers" > "$tmp/list" || { rm -rf "$tmp"; return 1; }
  # Accept a one-key list or two-key bridge, but authenticate with ONLY the pinned
  # key. Merely including that public key must not authorize an attacker's signature.
  count=$(grep -cv '^[[:space:]]*\(#\|$\)' "$tmp/list")
  sed -n 's/^brain-sync namespaces="git" \(ssh-ed25519 [A-Za-z0-9+/=]*\)$/\1/p' "$tmp/list" > "$tmp/keys"
  keys=$(wc -l < "$tmp/keys" | tr -d ' ')
  if { [ "$count" != 1 ] && [ "$count" != 2 ]; } || [ "$keys" != "$count" ]; then
    rm -rf "$tmp"; return 1
  fi
  : > "$tmp/pinned"
  while IFS= read -r pub; do
    printf '%s\n' "$pub" > "$tmp/key.pub"
    fingerprint=$(ssh-keygen -lf "$tmp/key.pub" -E sha256 2>/dev/null | awk '{print $2}')
    [ -n "$fingerprint" ] || { rm -rf "$tmp"; return 1; }
    if [ "$fingerprint" = "$BOOTSTRAP_SIGNER_FINGERPRINT" ]; then
      printf 'brain-sync namespaces="git" %s\n' "$pub" >> "$tmp/pinned"
    fi
  done < "$tmp/keys"
  if ! trust_verify "$tmp/pinned" "$sha"; then rm -rf "$tmp"; return 1; fi
  # A fetched bootstrap candidate is first checked without installing trust, then
  # selfchecked. A failed initial selfcheck leaves the existing legacy path retryable.
  if [ "${2:-}" = check ]; then rm -rf "$tmp"; return 0; fi
  { printf '# signed-anchor: %s\n' "$sha"; cat "$tmp/list"; } > "$tmp/allowed_signers"
  chmod 600 "$tmp/allowed_signers"
  rm -f "$tmp/list" "$tmp/key.pub" "$tmp/keys" "$tmp/pinned"
  mv "$tmp" "$TRUST_DIR"
}
trust_advance(){ trust_write "$1" "$SIGNERS"; }
trust_rotate(){
  local tmp; tmp=$(mktemp "$TRUST_DIR/.rotation.XXXXXX") || return 1
  # Only a signed object's list is eligible; malformed/empty lists cannot strand the Mac.
  git -C "$ENGINE" show "$1:config/allowed_signers" > "$tmp" &&
    trust_verify "$tmp" "$1" && trust_write "$1" "$tmp"
  local rc=$?; rm -f "$tmp"; return "$rc"
}
# --- end signed trust

echo "Fetching the sync engine..."
# Serialize with the installed launcher while authenticating/replacing the engine.
LOCK="$STATE/run.lock"; LOG="$STATE/sync.log"
log(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
# --- lock: IDENTICAL COPY in lib/common.sh and lib/launcher.sh (tests assert byte equality).
# The launcher must not source engine files, or a broken update could take down its own
# rollback, so this is duplicated on purpose rather than shared.
#
# A cycle runs every 300s and takes seconds, so SKIPPING one is harmless while running two at
# once is not. Every ambiguity below therefore fails closed.
#
# Staleness is decided by AGE, never by a pid. Three rounds of review broke the pid version,
# each time differently, and both remaining failures were structural: the pid file cannot be
# written atomically with the mkdir that creates the lock, so a crash in between left a lock
# nobody could ever break (the Mac stops syncing forever, silently), and a pid reused after a
# reboot made a stranger look like the owner. Neither is reachable without consulting pids.
LOCK_STALE_SECONDS="${LOCK_STALE_SECONDS:-1800}"

_lock_age_seconds(){
  local t; t=$(stat -f %m "$1" 2>/dev/null) || return 1
  echo $(( $(date +%s) - t ))
}

acquire_lock(){
  if ! mkdir "$LOCK" 2>/dev/null; then
    local age; age=$(_lock_age_seconds "$LOCK") || return 1
    # Two checks, and they are not redundant even though removing this one keeps every test
    # green and every probe clean (measured: 6 runs, 3 contenders against a live holder, 0
    # intruders either way). The SAFETY property is the seized-age re-check below. This one
    # narrows the window: without it every contender moves the live lock aside and puts it
    # back, so $LOCK briefly does not exist on each attempt. Keep both; do not "simplify".
    [ "$age" -ge "$LOCK_STALE_SECONDS" ] || return 1
    local seized="$LOCK.dead.$$"
    mv "$LOCK" "$seized" 2>/dev/null || return 1
    # Only one contender can win that rename, but it was judged BEFORE the rename: if another
    # contender took over in between we have just seized a live lock. Detect it by the age of
    # what we actually got, put it back, and give up. The exposure is the microseconds between
    # the two calls, and we never proceed.
    local got; got=$(_lock_age_seconds "$seized")
    if [ -z "$got" ] || [ "$got" -lt "$LOCK_STALE_SECONDS" ]; then
      mv "$seized" "$LOCK" 2>/dev/null || rm -rf "$seized"
      return 1
    fi
    log "broke a lock abandoned ${got}s ago"
    rm -rf "$seized"
    mkdir "$LOCK" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" > "$LOCK/pid"   # informational for an operator reading the folder; never arbitration
  # shellcheck disable=SC2329  # invoked indirectly by trap
  cleanup_lock(){
    [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"
    return 0
  }
  trap 'cleanup_lock' EXIT
  trap 'cleanup_lock; exit 130' INT
  trap 'cleanup_lock; exit 143' TERM
  return 0
}
acquire_lock || { echo "Sync is running; retry setup shortly." >&2; exit 1; }
if [ -d "$ENGINE/.git" ]; then
  git -C "$ENGINE" fetch --quiet origin main || exit 1
elif [ -e "$ENGINE" ]; then
  echo "Sync engine destination is not a usable git repo: $ENGINE" >&2; exit 1
else
  git clone --no-checkout --quiet "$BRAIN_SYNC_REMOTE" "$ENGINE" || exit 1
  git -C "$ENGINE" fetch --quiet origin main || exit 1
fi
candidate=$(git -C "$ENGINE" rev-parse 'FETCH_HEAD^{commit}') || exit 1
if ! trust_bootstrap "$candidate" check; then
  echo "Sync engine signature, bootstrap pin or ancestry rejected; nothing from it was run." >&2
  exit 1
fi
# An existing trust store still records every authenticated tip before its selfcheck,
# preserving the anti-rollback high-water mark even when that release is broken.
if [ -e "$TRUST_DIR" ] || [ -L "$TRUST_DIR" ]; then
  trust_advance "$candidate" || exit 1
fi
# Remember the installed checkout before testing a bootstrap candidate. Without trust
# installed yet, a failed selfcheck must leave the legacy path available for retry.
previous=$(git -C "$ENGINE" rev-parse HEAD 2>/dev/null || echo "")
git -C "$ENGINE" -c core.hooksPath=/dev/null reset --quiet --hard "$candidate" &&
  git -C "$ENGINE" clean -ffdqx || exit 1
if ! bash -n "$ENGINE/lib/launcher.sh" || ! bash "$ENGINE/sync.sh" --selfcheck; then
  if [ -e "$TRUST_DIR" ] || [ -L "$TRUST_DIR" ]; then
    previous=$(cat "$STATE/engine-verified" 2>/dev/null || echo "")
    trust_sha "$previous" && trust_verify "$SIGNERS" "$previous" &&
      git -C "$ENGINE" merge-base --is-ancestor "$previous" "$candidate" || previous=""
  fi
  if trust_sha "$previous"; then
    git -C "$ENGINE" -c core.hooksPath=/dev/null reset --quiet --hard "$previous"
    git -C "$ENGINE" clean -ffdqx
  fi
  echo "Signed engine failed selfcheck; setup stopped." >&2
  exit 1
fi
# Stage the authenticated launcher before installing trust, then replace it immediately
# under the same lock. Later rotation/setup failures must not leave a legacy updater active.
launcher_tmp=$(mktemp "$STATE/.launcher.XXXXXX") || exit 1
install -m 0755 "$ENGINE/lib/launcher.sh" "$launcher_tmp" || { rm -f "$launcher_tmp"; exit 1; }
trust_bootstrap "$candidate" || { rm -f "$launcher_tmp"; exit 1; }
mv -f "$launcher_tmp" "$STATE/launcher.sh" || { rm -f "$launcher_tmp"; exit 1; }
trust_advance "$candidate" || exit 1
tmp=$(mktemp "$STATE/.engine-verified.XXXXXX") || exit 1
printf '%s\n' "$candidate" > "$tmp" && mv -f "$tmp" "$STATE/engine-verified" || exit 1
trust_rotate "$candidate" || { echo "Invalid signed key rotation." >&2; exit 1; }
cleanup_lock
trap - EXIT INT TERM
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
  # Codex re-review of 0b5862b, non-blocking: this only ever runs ONCE per alias (the grep
  # above makes every later call a no-op), so BatchMode/ConnectTimeout here only ever reach a
  # Mac set up AFTER this ships - lib/common.sh's GIT_SSH_COMMAND is what reaches an
  # already-set-up Mac. Written here too anyway: belt and suspenders, and it means a fresh
  # install's ssh config carries the same timeout even for a direct `ssh`/`git` invocation that
  # does not go through the engine's own environment.
  grep -q "^Host $alias$" "$SSH_CONFIG" 2>/dev/null && return 0
  if [ -s "$SSH_CONFIG" ] && [ "$(tail -c 1 "$SSH_CONFIG" | wc -l)" -eq 0 ]; then
    printf '\n' >> "$SSH_CONFIG"
  fi
  printf 'Host %s\n  HostName github.com\n  User git\n  IdentityFile "%s"\n  IdentitiesOnly yes\n  BatchMode yes\n  ConnectTimeout 15\n' "$alias" "$key" >> "$SSH_CONFIG"
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
# setup.sh's folder is always $HOME/Serlinolab) and STATE/TEAM/PERSON_SLUG from that, which would
# silently point acquire_lock's own lock, and complete_setup's own targets, at the wrong place
# (and re-derive the wrong person) whenever $BRAIN_ROOT happens to be set in the environment
# for something else entirely. Restore this script's own values immediately - the ONE thing
# this source is for is acquire_lock/cleanup_lock.
ROOT="$HOME/Serlinolab"; STATE="$ROOT/.state"; LOCK="$STATE/run.lock"; TEAM="$ROOT/team"
PERSON_SLUG="$(cat "$STATE/person" 2>/dev/null || true)"
# The "Serlino Brain" launcher (lib/brain_launcher.sh), built under the same lock a sync cycle
# builds it under, so the two can never race. Only after a complete setup - a pending or refused
# Brain folder is left to a later sync cycle. Never fails setup: a missing library is a no-op.
# shellcheck source=lib/brain_launcher.sh
source "$ENGINE/lib/brain_launcher.sh" 2>/dev/null || ensure_brain_launcher(){ :; }
complete_setup_rc=1
if acquire_lock; then
  complete_setup; complete_setup_rc=$?
  [ "$complete_setup_rc" -ne 0 ] || ensure_brain_launcher
  cleanup_lock
else
  echo "Setup is already being completed in the background - waiting briefly for it to finish..." >&2
  sleep 2
  if acquire_lock; then
    complete_setup; complete_setup_rc=$?
    [ "$complete_setup_rc" -ne 0 ] || ensure_brain_launcher
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
