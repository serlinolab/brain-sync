#!/bin/bash
# AC-9: self-update from THIS repo (brain-sync), never from the Brain, with
# rollback to the last working copy when a new one fails to run. Installed
# by setup.sh outside the engine clone it manages, and self-contained (no
# `source` of engine files) so a broken update can't take down the rollback.
set -u
ROOT="${BRAIN_ROOT:-$HOME/Serlinolab}"
STATE="$ROOT/.state"; ENGINE="$STATE/engine"; LOG="$STATE/sync.log"
REMOTE="${BRAIN_SYNC_REMOTE:-https://github.com/serlinolab/brain-sync.git}"
# The self-update's https git had no limit either: a transfer below 1000 bytes/s for 60 s is now
# abandoned (git's own low-speed limit) instead of hanging the cycle. Exported, so sync.sh and every
# git it runs inherit it too.
export GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1000}"
export GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-60}"
mkdir -p "$STATE"
log(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

LOCK="$STATE/run.lock"
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
acquire_lock || exit 0

# capability: safe-stop
# (Read by the SerlinoLab Brain app before it uses `launchctl kickstart -k` on a stuck run.)
#
# Every long step (clone, fetch, selfcheck, the cycle itself) runs as a background child that this
# script WAITS for: bash runs a trap only once a foreground command returns, but interrupts `wait`
# at once. So TERM (what `kickstart -k` and logout send) stops whatever is running in ANY phase and
# frees the lock immediately, well inside launchd's 20 s before it would SIGKILL us - a SIGKILLed
# launcher leaves the lock for LOCK_STALE_SECONDS (MAX-1629, 2026-10-03).
STOP_GRACE_SECONDS=5
CHILD_PID=""
# The pid and all its descendants, children first (collected BEFORE signalling, so a process that
# outlives its parent is still on the list for the KILL pass).
tree_pids(){
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do tree_pids "$child"; done
  printf '%s\n' "$1"
}
stop_tree(){
  local pids p i alive
  pids=$(tree_pids "$1")
  for p in $pids; do kill -TERM "$p" 2>/dev/null; done
  for i in $(seq 1 "$STOP_GRACE_SECONDS"); do
    alive=""
    for p in $pids; do kill -0 "$p" 2>/dev/null && { alive=1; break; }; done
    [ -z "$alive" ] && return 0
    sleep 1
  done
  for p in $pids; do kill -KILL "$p" 2>/dev/null; done
}
# Every direct child of this launcher, not just CHILD_PID: a TERM can land between a `&` and the
# assignment of `$!`, and the watchdog is a child too.
stop_all(){
  local child
  for child in $(pgrep -P $$ 2>/dev/null); do stop_tree "$child"; done
}
trap 'stop_all; cleanup_lock; exit 143' TERM
trap 'stop_all; cleanup_lock; exit 130' INT
# Runs "$@" as an interruptible child; returns its status.
run_child(){ "$@" & CHILD_PID=$!; wait "$CHILD_PID"; local rc=$?; CHILD_PID=""; return "$rc"; }

# Without Apple's developer tools, /usr/bin/git is a stub that pops Apple's install dialog.
# This runs from launchd, so it must never reach git then: skip the cycle and let a person
# run setup, which can start the install. (Same probe as xcode_clt_ready in lib/common.sh.)
_clt=$(xcode-select -p 2>/dev/null) && [ -d "$_clt" ] || { log "self-update: Apple developer tools missing, cycle skipped"; exit 0; }

# --- signed trust: identical in setup.sh and lib/launcher.sh; never source from a fetched tree.
# Pin the dedicated release key in BOTH entry points before shipping. No environment override.
# Bootstrap accepts only ssh-ed25519 keys (including both keys during a rotation bridge).
BOOTSTRAP_SIGNER_FINGERPRINT='REPLACE_WITH_MAX_SSH_SHA256_FINGERPRINT'
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

update_error(){
  export BRAIN_UPDATE_ERROR="$*"
  log "self-update: $*"
}
# Only an already installed checkout may continue while bootstrap is pending.
# A fresh --no-checkout clone must never execute an unauthenticated candidate.
legacy_current=0
[ -d "$ENGINE/.git" ] && [ -f "$ENGINE/sync.sh" ] && legacy_current=1
update_engine(){
  if [ ! -d "$ENGINE/.git" ]; then
    run_child git clone --no-checkout --quiet "$REMOTE" "$ENGINE" >/dev/null 2>&1 || { log "self-update: initial clone failed"; return 1; }
  fi
  cd "$ENGINE" || return 1
  VERIFIED_FILE="$STATE/engine-verified"
  fetched=0
  # Legacy engine-verified means only selfchecked. Authenticate HEAD independently on transition.
  if [ ! -e "$TRUST_DIR" ] && [ ! -L "$TRUST_DIR" ]; then
    initial=$(git rev-parse HEAD 2>/dev/null || echo "")
    if ! trust_bootstrap "$initial"; then
      if run_child git fetch --quiet origin main 2>/dev/null; then
        fetched=1
        candidate=$(git rev-parse 'FETCH_HEAD^{commit}' 2>/dev/null || echo "")
        if trust_bootstrap "$candidate" check; then
          if git -c core.hooksPath=/dev/null reset --quiet --hard "$candidate" && git clean -ffdqx &&
             bash -n sync.sh lib/*.sh 2>>"$LOG" && run_child bash sync.sh --selfcheck 2>>"$LOG" &&
             trust_bootstrap "$candidate"; then
            initial="$candidate"
          else
            # This was an initial bootstrap, not an accepted release: retain the
            # previously installed path and retry bootstrap next cycle.
            if [ "$legacy_current" = 1 ]; then
              git -c core.hooksPath=/dev/null reset --quiet --hard "$initial" && git clean -ffdqx || return 1
            fi
          fi
        fi
      else
        log "self-update: bootstrap fetch failed; retrying next cycle"
      fi
      if [ ! -d "$TRUST_DIR" ]; then
        update_error "bootstrap signature/pin or selfcheck rejected; continuing installed code; retrying next cycle"
        [ "$legacy_current" = 1 ] && return 0
        return 1
      fi
    fi
    tmp=$(mktemp "$STATE/.engine-verified.XXXXXX") || return 1
    printf '%s\n' "$initial" > "$tmp" && mv -f "$tmp" "$VERIFIED_FILE" || return 1
  fi
  trust_private "$TRUST_DIR" 700 && trust_private "$SIGNERS" 600 || {
    update_error "trust store missing, unsafe or corrupt; execution stopped"; return 1;
  }
  anchor=$(trust_anchor)
  trust_sha "$anchor" || { update_error "invalid signed anchor; execution stopped"; return 1; }
  prev=$(cat "$VERIFIED_FILE" 2>/dev/null || echo "")
  # A working fallback must be authenticated and on the accepted history, never arbitrary HEAD.
  if ! trust_sha "$prev" || ! trust_verify "$SIGNERS" "$prev" ||
     ! git merge-base --is-ancestor "$prev" "$anchor"; then
    update_error "no authenticated working release; execution stopped"; return 1
  fi
  if [ "$fetched" = 1 ] || run_child git fetch --quiet origin main 2>/dev/null; then
    new=$(git rev-parse 'FETCH_HEAD^{commit}' 2>/dev/null || echo "")
    if ! trust_check "$new"; then
      update_error "signature or ancestry rejected $new; keeping $prev"
    elif ! trust_advance "$new"; then
      update_error "cannot persist signed anchor; keeping $prev"
    elif [ "$new" != "$prev" ]; then
      if git -c core.hooksPath=/dev/null reset --quiet --hard "$new" && git clean -ffdqx &&
         bash -n sync.sh lib/*.sh 2>>"$LOG" && run_child bash sync.sh --selfcheck 2>>"$LOG"; then
        tmp=$(mktemp "$STATE/.engine-verified.XXXXXX") || return 1
        printf '%s\n' "$new" > "$tmp" && mv -f "$tmp" "$VERIFIED_FILE" || return 1
        prev="$new"
        trust_rotate "$new" || update_error "signed key rotation invalid; retaining pinned keys"
        log "self-update: updated to $new"
      else
        update_error "$new failed selfcheck, restoring $prev"
      fi
    else
      # Retry an interrupted rotation after the working-release marker was persisted.
      trust_rotate "$new" || update_error "signed key rotation invalid; retaining pinned keys"
    fi
  else
    log "self-update: fetch failed; keeping $prev"
  fi
  # Also repair an interrupted checkout or dirty tree while offline. Never run leftover files.
  git -c core.hooksPath=/dev/null reset --quiet --hard "$prev" && git clean -ffdqx || return 1
  export BRAIN_SIGNED_ANCHOR="$(trust_anchor)"
}
unset BRAIN_UPDATE_ERROR BRAIN_SIGNED_ANCHOR
update_engine || exit 1

[ "${1:-}" = "--selfcheck-only" ] && exit 0

# The cycle, with a watchdog: one still running after CYCLE_TIMEOUT_SECONDS is stopped with
# everything it started (a dead network call once held a Mac for 51 minutes, and launchd never
# starts a run while one is alive). Below LOCK_STALE_SECONDS, so the lock is always released by
# its owner, never broken as stale.
CYCLE_TIMEOUT_SECONDS="${CYCLE_TIMEOUT_SECONDS:-1200}"
BRAIN_SYNC_LOCK_HELD=1 bash "$ENGINE/sync.sh" &
CHILD_PID=$!
# A subshell resets the traps above, so the watchdog never touches the lock itself.
(
  waited=0
  while kill -0 "$CHILD_PID" 2>/dev/null; do
    sleep 1; waited=$((waited + 1))
    if [ "$waited" -ge "$CYCLE_TIMEOUT_SECONDS" ]; then
      log "stopped a sync cycle still running after $CYCLE_TIMEOUT_SECONDS s"
      stop_tree "$CHILD_PID"
      exit 0
    fi
  done
) &
WATCH_PID=$!
wait "$CHILD_PID"; rc=$?
# Not killed: if it fired, it is finishing its KILL pass; otherwise it ends within a second.
wait "$WATCH_PID" 2>/dev/null
exit "$rc"
