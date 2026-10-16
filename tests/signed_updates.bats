#!/usr/bin/env bats
load 'helpers'
setup() {
  brain_test_setup
  make_fake_brain_sync_origin
  export BRAIN_SYNC_REMOTE="$FAKE_ORIGIN"
  bash "$TEST_LAUNCHER" --selfcheck-only
  GOOD=$(git -C "$STATE/engine" rev-parse HEAD)
}
teardown() { brain_test_teardown; rm -rf "$BRAIN_SYNC_WORK"; }

push_payload() {
  printf '#!/bin/bash\necho executed >> "$BRAIN_ROOT/untrusted-ran"\nexit 0\n' > "$BRAIN_SYNC_WORK/sync.sh"
  git -C "$BRAIN_SYNC_WORK" add -A
}
assert_rejected() {
  run bash "$TEST_LAUNCHER"
  [ "$status" -eq 0 ]
  [ "$(git -C "$STATE/engine" rev-parse HEAD)" = "$GOOD" ]
  [ "$(cat "$STATE/engine-verified")" = "$GOOD" ]
  [ ! -e "$BRAIN_ROOT/untrusted-ran" ]
  grep -q 'signature or ancestry rejected' "$LOG"
}

@test "unsigned update is rejected before checkout or selfcheck and trusted cycle reports failure" {
  push_payload
  git -C "$BRAIN_SYNC_WORK" -c commit.gpgsign=false -c user.name=test -c user.email=test@example.com commit -qm unsigned
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  assert_rejected
  # Also repair an unsigned checkout left behind by an interrupted legacy updater.
  git -C "$STATE/engine" fetch -q origin main
  git -C "$STATE/engine" reset -q --hard FETCH_HEAD
  assert_rejected
}

@test "unknown signing key and its replacement repo allowed_signers cannot authorize an update" {
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/unknown"
  printf 'brain-sync namespaces="git" %s\n' "$(awk '{print $1 " " $2}' "$HOME/unknown.pub")" > "$BRAIN_SYNC_WORK/config/allowed_signers"
  push_payload
  git -C "$BRAIN_SYNC_WORK" -c user.signingkey="$HOME/unknown" -c user.name=test -c user.email=test@example.com commit -qm attacker
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  before=$(shasum "$STATE/update-trust/allowed_signers")
  assert_rejected
  [ "$(shasum "$STATE/update-trust/allowed_signers")" = "$before" ]
}

@test "allowed signed descendant is checked and executed" {
  push_payload
  git_commit "$BRAIN_SYNC_WORK" signed
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  run bash "$TEST_LAUNCHER"
  [ "$status" -eq 0 ]
  [ -e "$BRAIN_ROOT/untrusted-ran" ]
  [ "$(git -C "$STATE/engine" rev-parse HEAD)" = "$(git -C "$BRAIN_SYNC_WORK" rev-parse HEAD)" ]
  [ "$(stat -f %Lp "$STATE/update-trust")" = 700 ]
  [ "$(stat -f %Lp "$STATE/update-trust/allowed_signers")" = 600 ]
}

@test "signed ancestor rollback and signed divergent force push are both rejected" {
  echo next > "$BRAIN_SYNC_WORK/next"
  git -C "$BRAIN_SYNC_WORK" add -A; git_commit "$BRAIN_SYNC_WORK" next
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  bash "$TEST_LAUNCHER" --selfcheck-only
  old="$GOOD"; GOOD=$(git -C "$STATE/engine" rev-parse HEAD)
  git -C "$BRAIN_SYNC_WORK" push -q --force origin "$old:main"
  assert_rejected
  git -C "$BRAIN_SYNC_WORK" reset -q --hard "$old"
  push_payload; git_commit "$BRAIN_SYNC_WORK" divergent
  git -C "$BRAIN_SYNC_WORK" push -q --force origin main
  assert_rejected
}

@test "dirty repo signers and payload are discarded even when fetch fails" {
  echo attacker > "$STATE/engine/config/allowed_signers"
  printf 'touch "$BRAIN_ROOT/untrusted-ran"\n' > "$STATE/engine/sync.sh"
  mv "$FAKE_ORIGIN" "$FAKE_ORIGIN.offline"
  bash "$TEST_LAUNCHER"
  [ ! -e "$BRAIN_ROOT/untrusted-ran" ]
  cmp "$STATE/engine/config/allowed_signers" "$BRAIN_SYNC_WORK/config/allowed_signers"
}

@test "failed signed selfcheck retains high-water mark and rejects a sibling repair" {
  break_origin_sync_sh
  failed=$(git -C "$BRAIN_SYNC_WORK" rev-parse HEAD)
  bash "$TEST_LAUNCHER" --selfcheck-only
  grep -qx "# signed-anchor: $failed" "$STATE/update-trust/allowed_signers"
  [ "$(git -C "$STATE/engine" rev-parse HEAD)" = "$GOOD" ]
  git -C "$BRAIN_SYNC_WORK" reset -q --hard "$GOOD"
  push_payload; git_commit "$BRAIN_SYNC_WORK" sibling
  git -C "$BRAIN_SYNC_WORK" push -q --force origin main
  assert_rejected
}

@test "old launcher installs signed transition; next cycle pins and rejects unsigned descendants" {
  rm -rf "$STATE/update-trust"
  cp "$REPO_ROOT/tests/fixtures/legacy_launcher.sh" "$STATE/launcher.sh"
  cp "$TEST_LAUNCHER" "$BRAIN_SYNC_WORK/lib/launcher.sh"
  cp "$REPO_ROOT/lib/launcher_refresh.sh" "$BRAIN_SYNC_WORK/lib/launcher_refresh.sh"
  cat > "$BRAIN_SYNC_WORK/sync.sh" <<'SCRIPT'
#!/bin/bash
[ "${1:-}" = --selfcheck ] && exit 0
STATE="$BRAIN_ROOT/.state"
log(){ :; }
source "$(dirname "$0")/lib/launcher_refresh.sh"
ensure_launcher_current
SCRIPT
  git -C "$BRAIN_SYNC_WORK" add -A; git_commit "$BRAIN_SYNC_WORK" transition
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  bash "$STATE/launcher.sh"
  cmp "$STATE/launcher.sh" "$TEST_LAUNCHER"
  [ ! -e "$STATE/update-trust" ]
  bash "$STATE/launcher.sh"
  GOOD=$(git -C "$STATE/engine" rev-parse HEAD)
  grep -qx "# signed-anchor: $GOOD" "$STATE/update-trust/allowed_signers"
  push_payload
  git -C "$BRAIN_SYNC_WORK" -c commit.gpgsign=false -c user.name=test -c user.email=test@example.com commit -qm unsigned
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  assert_rejected
}

@test "bootstrap pin mismatch and unsigned bootstrap cannot execute engine code" {
  rm -rf "$STATE/update-trust" "$STATE/engine"
  push_payload; git_commit "$BRAIN_SYNC_WORK" signed
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  run bash "$REPO_ROOT/lib/launcher.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$BRAIN_ROOT/untrusted-ran" ]
  [ ! -e "$STATE/engine/sync.sh" ]
  git -C "$BRAIN_SYNC_WORK" -c commit.gpgsign=false -c user.name=test -c user.email=test@example.com commit --allow-empty -qm unsigned
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  rm -rf "$STATE/engine"
  run bash "$TEST_LAUNCHER"
  [ "$status" -ne 0 ]
  [ ! -e "$BRAIN_ROOT/untrusted-ran" ]
  [ ! -e "$STATE/engine/sync.sh" ]
}

@test "unsafe external signer permissions fail closed" {
  chmod 644 "$STATE/update-trust/allowed_signers"
  run bash "$TEST_LAUNCHER"
  [ "$status" -ne 0 ]
  grep -q 'trust store missing, unsafe or corrupt' "$LOG"
}

@test "signed bridge authorizes next key and signed removal revokes old key" {
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/next-key"
  printf 'brain-sync namespaces="git" %s\n' "$(awk '{print $1 " " $2}' "$HOME/next-key.pub")" >> "$BRAIN_SYNC_WORK/config/allowed_signers"
  git -C "$BRAIN_SYNC_WORK" add -A; git_commit "$BRAIN_SYNC_WORK" bridge
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  bash "$TEST_LAUNCHER" --selfcheck-only
  git -C "$BRAIN_SYNC_WORK" config user.signingkey "$HOME/next-key"
  tail -1 "$BRAIN_SYNC_WORK/config/allowed_signers" > "$HOME/new-list"
  cp "$HOME/new-list" "$BRAIN_SYNC_WORK/config/allowed_signers"
  git -C "$BRAIN_SYNC_WORK" add -A; git_commit "$BRAIN_SYNC_WORK" revoke
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  bash "$TEST_LAUNCHER" --selfcheck-only
  GOOD=$(git -C "$STATE/engine" rev-parse HEAD)
  grep -qF "$(awk '{print $2}' "$HOME/next-key.pub")" "$STATE/update-trust/allowed_signers"
  git -C "$BRAIN_SYNC_WORK" config user.signingkey "$SIGNING_KEY"
  push_payload; git_commit "$BRAIN_SYNC_WORK" revoked
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  assert_rejected
}

@test "installer and launcher carry identical self-contained trust code" {
  sed -n '/^# --- signed trust:/,/^# --- end signed trust/p' "$REPO_ROOT/setup.sh" > "$HOME/setup-trust"
  sed -n '/^# --- signed trust:/,/^# --- end signed trust/p' "$REPO_ROOT/lib/launcher.sh" > "$HOME/launcher-trust"
  cmp "$HOME/setup-trust" "$HOME/launcher-trust"
}

@test "unsigned transition keeps publishing heartbeat and recovers when a signed tip arrives later" {
  make_fake_team_repo
  make_fake_mirror
  rm -rf "$STATE/update-trust"
  cp "$REPO_ROOT/tests/fixtures/legacy_launcher.sh" "$STATE/launcher.sh"
  cp "$REPO_ROOT/sync.sh" "$BRAIN_SYNC_WORK/sync.sh"
  cp "$REPO_ROOT"/lib/*.sh "$BRAIN_SYNC_WORK/lib/"
  cp "$TEST_LAUNCHER" "$BRAIN_SYNC_WORK/lib/launcher.sh"
  git -C "$BRAIN_SYNC_WORK" add -A; git_commit "$BRAIN_SYNC_WORK" transition-T
  git -C "$BRAIN_SYNC_WORK" -c commit.gpgsign=false -c user.name=GitHub -c user.email=web@example.com commit --allow-empty -qm web-merge
  unsigned=$(git -C "$BRAIN_SYNC_WORK" rev-parse HEAD)
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  # Cycle 1: legacy updater installs the new launcher from the unsigned tip.
  bash "$STATE/launcher.sh"
  cmp "$STATE/launcher.sh" "$TEST_LAUNCHER"
  [ ! -e "$STATE/update-trust" ]
  branch="status/testperson-$(cat "$STATE/machine-id")"
  for cycle in 2 3; do
    # Force an actual publication each cycle, even for an unchanged condition.
    rm -f "$STATE/heartbeat-last"
    bash "$STATE/launcher.sh"
    [ "$(git -C "$STATE/engine" rev-parse HEAD)" = "$unsigned" ]
    [ ! -e "$STATE/update-trust" ]
    [ -f "$STATE/heartbeat-last" ]
    git -C "$BRAIN_ROOT/origin-team.git" show "$branch:status.txt" > "$HOME/status"
    grep -q '^result: problem - self-update: bootstrap' "$HOME/status"
    grep -qx 'signed updates: pending-transition' "$HOME/status"
  done
  # Only the remote changes. No operator repairs any installed Mac state.
  git -C "$BRAIN_SYNC_WORK" -c user.name=Max -c user.email=max@example.com commit --allow-empty -qm signed-repair
  repaired=$(git -C "$BRAIN_SYNC_WORK" rev-parse HEAD)
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  bash "$STATE/launcher.sh"
  [ "$(git -C "$STATE/engine" rev-parse HEAD)" = "$repaired" ]
  [ "$(cat "$STATE/engine-verified")" = "$repaired" ]
  git -C "$BRAIN_ROOT/origin-team.git" show "$branch:status.txt" > "$HOME/status"
  grep -qx 'result: ok' "$HOME/status"
  grep -qx 'signed updates: enforced' "$HOME/status"
  grep -qx "signed anchor: $repaired" "$HOME/status"
  # A transient engine-fetch failure does not turn a successful sync red.
  mv "$FAKE_ORIGIN" "$FAKE_ORIGIN.offline"
  rm -f "$STATE/heartbeat-last"
  bash "$STATE/launcher.sh"
  [ -f "$STATE/heartbeat-last" ]
  git -C "$BRAIN_ROOT/origin-team.git" show "$branch:status.txt" | grep -qx 'result: ok'
}

@test "bootstrap accepts an old-key-signed two-key bridge but not a signature by its unpinned key" {
  rm -rf "$STATE/update-trust"
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/next-key"
  printf 'brain-sync namespaces="git" %s\n' "$(awk '{print $1 " " $2}' "$HOME/next-key.pub")" >> "$BRAIN_SYNC_WORK/config/allowed_signers"
  push_payload
  git -C "$BRAIN_SYNC_WORK" -c user.signingkey="$HOME/next-key" -c user.name=test -c user.email=test@example.com commit -qm unpinned-bridge
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  # Local HEAD must also fail bootstrap so the fetched bridge is tried.
  git -C "$STATE/engine" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false commit --allow-empty -qm unsigned-local
  bash "$TEST_LAUNCHER"
  [ ! -e "$STATE/update-trust" ]
  [ ! -e "$BRAIN_ROOT/untrusted-ran" ]
  git -C "$BRAIN_SYNC_WORK" -c user.name=test -c user.email=test@example.com commit --allow-empty -qm pinned-bridge
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  bash "$TEST_LAUNCHER"
  [ -e "$BRAIN_ROOT/untrusted-ran" ]
  [ "$(grep -c '^brain-sync ' "$STATE/update-trust/allowed_signers")" -eq 2 ]
}

@test "PGP GOODSIG with undefined trust cannot bypass SSH pins in either verifier" {
  push_payload
  tree=$(git -C "$BRAIN_SYNC_WORK" write-tree)
  forged=$({
    printf 'tree %s\nparent %s\n' "$tree" "$GOOD"
    printf 'author attacker <a@example.com> 1700000000 +0000\ncommitter attacker <a@example.com> 1700000000 +0000\n'
    printf 'gpgsig -----BEGIN PGP SIGNATURE-----\n fake\n -----END PGP SIGNATURE-----\n\nforged\n'
  } | git -C "$BRAIN_SYNC_WORK" hash-object -t commit -w --stdin)
  cat > "$HOME/fake-gpg" <<'STUB'
#!/bin/bash
cat >/dev/null
printf 'called\n' >> "$HOME/gpg-called"
printf '%s\n' '[GNUPG:] NEWSIG' '[GNUPG:] GOODSIG 0123456789ABCDEF Attacker' '[GNUPG:] VALIDSIG 0123456789ABCDEF0123456789ABCDEF01234567 2023-11-14 1700000000 0 4 0 1 10 00 0123456789ABCDEF0123456789ABCDEF01234567' '[GNUPG:] TRUST_UNDEFINED 0 pgp'
STUB
  chmod +x "$HOME/fake-gpg"
  git -C "$BRAIN_SYNC_WORK" -c gpg.format=ssh -c gpg.program="$HOME/fake-gpg" verify-commit "$forged"
  [ -f "$HOME/gpg-called" ] # Prove the vulnerable command accepts this fixture.
  rm "$HOME/gpg-called"
  git -C "$BRAIN_SYNC_WORK" update-ref refs/heads/main "$forged"
  git -C "$BRAIN_SYNC_WORK" push -q origin main
  git -C "$STATE/engine" config gpg.program "$HOME/fake-gpg"
  git -C "$STATE/engine" config gpg.x509.program "$HOME/fake-gpg"
  assert_rejected
  [ ! -e "$HOME/gpg-called" ]
  for entry in "$REPO_ROOT/setup.sh" "$REPO_ROOT/lib/launcher.sh"; do
    sed -n '/^# --- signed trust:/,/^# --- end signed trust/p' "$entry" > "$HOME/trust-functions"
    run bash -c 'ENGINE="$STATE/engine"; source "$HOME/trust-functions"; trust_verify "$SIGNERS" "$1"' _ "$forged"
    [ "$status" -ne 0 ]
  done
  [ ! -e "$HOME/gpg-called" ]
}
