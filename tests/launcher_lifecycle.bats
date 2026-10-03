#!/usr/bin/env bats
# MAX-1629 follow-ups 6 and 8, plus the gap behind them (2026-10-03):
# - the installed launcher ($STATE/launcher.sh) was copied once by setup.sh and NEVER refreshed, so
#   nothing changed in lib/launcher.sh ever reached a Mac (#17's https limit included);
# - a cycle stuck anywhere stalled syncing forever (launchd won't start a run while one is alive);
# - `launchctl kickstart -k` on a stuck run could not stop it lock-safely (bash defers a TERM trap
#   until its foreground child returns).
load 'helpers'
# A test that hangs is a failing test, not a stuck suite (the bug under test IS a hang).
BATS_TEST_TIMEOUT=60

setup() { brain_test_setup; make_fake_brain_sync_origin; MARK_ARG="brain-test-$$-$RANDOM"; export MARK_ARG; }
teardown() { pkill -f "sleep 7$MARK_ARG" 2>/dev/null; brain_test_teardown; rm -rf "$BRAIN_SYNC_WORK"; }

# A fake engine whose sync.sh starts a child and then blocks, both recognisable by $MARK_ARG.
push_stuck_engine() {
  cat > "$BRAIN_SYNC_WORK/sync.sh" <<SCRIPT
#!/bin/bash
[ "\${1:-}" = "--selfcheck" ] && exit 0
sh -c 'exec -a "sleep 7$MARK_ARG" sleep 600' &
exec -a "sleep 7$MARK_ARG" sleep 600
SCRIPT
  git -C "$BRAIN_SYNC_WORK" add -A; git_commit "$BRAIN_SYNC_WORK" stuck; git -C "$BRAIN_SYNC_WORK" push -q origin main
}
push_engine_exiting() {
  printf '#!/bin/bash\n[ "${1:-}" = "--selfcheck" ] && exit 0\nexit %s\n' "$1" > "$BRAIN_SYNC_WORK/sync.sh"
  git -C "$BRAIN_SYNC_WORK" add -A; git_commit "$BRAIN_SYNC_WORK" "exit $1"; git -C "$BRAIN_SYNC_WORK" push -q origin main
}
stuck_alive() { pgrep -f "sleep 7$MARK_ARG" >/dev/null; }

# --- 6: watchdog ---------------------------------------------------------------------------------

@test "a cycle stuck past the time limit is stopped with everything it started, and the lock is freed" {
  push_stuck_engine
  local start=$SECONDS
  CYCLE_TIMEOUT_SECONDS=2 BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" run /bin/bash "$REPO_ROOT/lib/launcher.sh"
  [ $((SECONDS - start)) -lt 20 ]
  sleep 1
  if stuck_alive; then false; fi
  [ ! -e "$STATE/run.lock" ]
  grep -q "stopped a sync cycle still running after 2 s" "$LOG"
}

@test "a normal cycle is untouched and its exit code still comes through" {
  push_engine_exiting 3
  CYCLE_TIMEOUT_SECONDS=30 BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" run /bin/bash "$REPO_ROOT/lib/launcher.sh"
  [ "$status" -eq 3 ]
  if grep -q "stopped a sync cycle" "$LOG"; then false; fi
}

# --- 8: lock-safe stop (what `launchctl kickstart -k` sends) -------------------------------------

@test "TERM to the launcher mid-cycle stops the whole cycle at once and frees the lock" {
  push_stuck_engine
  CYCLE_TIMEOUT_SECONDS=600 BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" /bin/bash "$REPO_ROOT/lib/launcher.sh" &
  local launcher=$!
  local i; for i in $(seq 1 50); do stuck_alive && break; sleep 0.2; done
  stuck_alive
  local start=$SECONDS
  kill -TERM "$launcher"
  wait "$launcher" || true
  [ $((SECONDS - start)) -lt 10 ]
  sleep 1
  if stuck_alive; then false; fi
  [ ! -e "$STATE/run.lock" ]
}

# Review 2026-10-03 (blocking): safe-stop must hold in EVERY phase, not only while sync.sh runs. During
# the self-update, bash would defer TERM until a slow `git fetch` returned; launchd SIGKILLs after
# 20 s and the lock stayed for 30 min. A stub git that blocks on `fetch` reproduces it.
@test "TERM during the self-update stops it at once and frees the lock" {
  /bin/bash "$REPO_ROOT/lib/launcher.sh" --selfcheck-only >/dev/null 2>&1 || true   # engine cloned
  BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" /bin/bash "$REPO_ROOT/lib/launcher.sh" --selfcheck-only
  local bin="$BRAIN_ROOT/bin"; mkdir -p "$bin"
  printf '%s\n' '#!/bin/bash' "[ \"\$1\" = fetch ] && exec -a \"sleep 7$MARK_ARG\" sleep 600" "exec $(command -v git) \"\$@\"" > "$bin/git"
  chmod +x "$bin/git"
  PATH="$bin:$PATH" BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" /bin/bash "$REPO_ROOT/lib/launcher.sh" &
  local launcher=$!
  local i; for i in $(seq 1 50); do stuck_alive && break; sleep 0.2; done
  stuck_alive
  local start=$SECONDS
  kill -TERM "$launcher"; wait "$launcher" || true
  [ $((SECONDS - start)) -lt 10 ]
  sleep 1
  if stuck_alive; then false; fi
  [ ! -e "$STATE/run.lock" ]
}

@test "a child that ignores TERM is killed anyway" {
  cat > "$BRAIN_SYNC_WORK/sync.sh" <<SCRIPT
#!/bin/bash
[ "\${1:-}" = "--selfcheck" ] && exit 0
bash -c 'trap "" TERM; exec -a "sleep 7$MARK_ARG" sleep 600' &
exec -a "sleep 7$MARK_ARG" sleep 600
SCRIPT
  git -C "$BRAIN_SYNC_WORK" add -A; git_commit "$BRAIN_SYNC_WORK" stubborn; git -C "$BRAIN_SYNC_WORK" push -q origin main
  CYCLE_TIMEOUT_SECONDS=2 BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" run /bin/bash "$REPO_ROOT/lib/launcher.sh"
  sleep 1
  if stuck_alive; then false; fi
}

@test "the launcher declares it can be stopped safely (the app checks this before kickstart -k)" {
  grep -qx '# capability: safe-stop' "$REPO_ROOT/lib/launcher.sh"
}

# --- the launcher reaches every Mac --------------------------------------------------------------

@test "an older installed launcher is replaced by the engine's, atomically" {
  printf '#!/bin/bash\n# an older launcher\n' > "$STATE/launcher.sh"
  local before; before=$(stat -f %i "$STATE/launcher.sh")
  ( source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/launcher_refresh.sh"; ensure_launcher_current )
  cmp -s "$STATE/launcher.sh" "$REPO_ROOT/lib/launcher.sh"
  [ "$(stat -f %i "$STATE/launcher.sh")" != "$before" ]   # renamed into place, never rewritten in place
  [ -x "$STATE/launcher.sh" ]
  grep -q "updated the installed launcher" "$LOG"
  grep -q "an older launcher" "$STATE/launcher.sh.prev"   # kept for a manual rollback
}

@test "an installed launcher already current is left alone" {
  install -m 0755 "$REPO_ROOT/lib/launcher.sh" "$STATE/launcher.sh"
  local before; before=$(stat -f %i "$STATE/launcher.sh")
  ( source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/launcher_refresh.sh"; ensure_launcher_current )
  [ "$(stat -f %i "$STATE/launcher.sh")" = "$before" ]
  if grep -q "launcher" "$LOG" 2>/dev/null; then false; fi
}

@test "no installed launcher: nothing is created (installing it is setup's job)" {
  ( source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/launcher_refresh.sh"; ensure_launcher_current )
  [ ! -e "$STATE/launcher.sh" ]
}

@test "a new launcher that doesn't parse never replaces the working one" {
  printf '#!/bin/bash\n# the working one\n' > "$STATE/launcher.sh"
  printf '#!/bin/bash\nif then fi (\n' > "$BRAIN_ROOT/broken-launcher.sh"
  ( source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/launcher_refresh.sh"
    LAUNCHER_SOURCE="$BRAIN_ROOT/broken-launcher.sh" ensure_launcher_current )
  grep -q "the working one" "$STATE/launcher.sh"
  grep -q "does not parse" "$LOG"
}

@test "a sync cycle refreshes the launcher" {
  printf '#!/bin/bash\n# an older launcher\n' > "$STATE/launcher.sh"
  run run_sync_cycle
  cmp -s "$STATE/launcher.sh" "$REPO_ROOT/lib/launcher.sh"
}

# Re-review 2026-10-03: a stop during `sync.sh --selfcheck` (now likely: Fix sends kickstart -k)
# left the engine reset to an UNVERIFIED commit; next run HEAD == origin/main, so the selfcheck was
# skipped for good. The last verified commit is now remembered in $STATE/engine-verified.
@test "an engine left on an unverified commit by an interrupted update is checked again, and rolled back if broken" {
  BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" /bin/bash "$REPO_ROOT/lib/launcher.sh" --selfcheck-only
  local good; good=$(git -C "$STATE/engine" rev-parse HEAD)
  [ "$(cat "$STATE/engine-verified")" = "$good" ]
  break_origin_sync_sh
  git -C "$STATE/engine" fetch -q origin main && git -C "$STATE/engine" reset -q --hard origin/main   # the interrupted run
  BRAIN_SYNC_REMOTE="$FAKE_ORIGIN" /bin/bash "$REPO_ROOT/lib/launcher.sh" --selfcheck-only
  [ "$(git -C "$STATE/engine" rev-parse HEAD)" = "$good" ]
  grep -q "failed selfcheck, restoring" "$LOG"
}
