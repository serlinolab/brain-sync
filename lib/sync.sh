#!/bin/bash
# Mirror sync, team sync, staleness, and the company README. Sourced by sync.sh.

online(){ git ls-remote --exit-code "$ONLINE_CHECK_REMOTE" HEAD >/dev/null 2>&1; }

# MAX-1515 fix 4b: a refused-then-later-swapped repo must never be touched just because it
# sits at the expected path - every mutating function below re-checks this first. Verifies
# BOTH the fetch URL and every push URL equal `expected` (a self-consistent fetch==push pair
# pointing at the WRONG remote would otherwise sail through). Missing dir/.git is not a
# mismatch - every caller already guards that separately.
remote_matches_expected(){
  local dir="$1" expected="$2" url push_urls
  [ -d "$dir/.git" ] || return 0
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
  [ "$url" = "$expected" ] || return 1
  # MAX-1515 fix 2: capture the command's own output AND exit status before reading it - a
  # `while read < <(cmd)` here would hide cmd's failure (0 lines of output looks identical to
  # "loop ran and every line matched"), silently treating a failed lookup as a match.
  push_urls=$(git -C "$dir" remote get-url --push --all origin 2>/dev/null) || return 1
  [ -n "$push_urls" ] || return 1
  while IFS= read -r url; do
    [ "$url" = "$expected" ] || return 1
  done <<<"$push_urls"
  return 0
}

# AC-2: files AND directories refuse writes - a stray new file can't be silently eaten by the next clean.
protect_readonly(){
  local dir="$1"
  find "$dir" -path "$dir/.git" -prune -o \( -type f -o -type d \) -exec chmod a-w {} + 2>/dev/null || true
}

# AC-8/AC-4: no git vocabulary in here. Regenerated every cycle since `git clean` would
# otherwise delete it (untracked). MAX-1515 (amended): the mirror lives beside team/, not
# nested inside it.
company_readme(){
  cat > "$MIRROR/READ ME FIRST.txt" <<'TXT'
This folder is the company's shared knowledge. It updates on its own -
you don't need to do anything to keep it current.

You cannot add, change, or remove anything in here. That is on purpose,
so everyone always sees the same version.

Have something to add or correct? Save it in the team folder, next
door, or tell Max directly.
TXT
}

sync_mirror(){
  # MAX-1515 review, "also check": `-d "$MIRROR/.git"` follows a symlink - a symlinked $MIRROR
  # pointing at a real git checkout elsewhere would otherwise pass straight through into fetch/
  # reset/clean below. `-L` catches it whether or not its target exists, before that.
  if [ -L "$MIRROR" ]; then
    log "the company folder is a symlink; refusing to touch it"
    return 1
  fi
  [ -d "$MIRROR/.git" ] || return 0
  if ! remote_matches_expected "$MIRROR" "$EXPECTED_MIRROR_REMOTE"; then
    log "mirror origin does not match the expected remote; refusing to touch it"
    return 1
  fi
  local rc=0
  if ! git -C "$MIRROR" fetch --quiet origin; then
    log "mirror fetch failed"
    protect_readonly "$MIRROR"
    return 1
  fi
  chmod -R u+w "$MIRROR" 2>/dev/null || true   # git needs write only after the fetch
  git -C "$MIRROR" reset --hard --quiet origin/main || rc=1
  [ "$rc" -eq 0 ] && git -C "$MIRROR" clean -ffdq || rc=1
  [ "$rc" -eq 0 ] && company_readme || rc=1
  protect_readonly "$MIRROR"
  [ "$rc" -eq 0 ] && log "mirror at $(git -C "$MIRROR" rev-parse --short HEAD)"
  return "$rc"
}

# AC-3/AC-7: a restore point exists before any network call; rejects an oversized file, and a
# file that looks like it holds a secret, before either is ever staged. Neither rejection
# blocks the rest of the cycle - every other staged file still commits.
commit_local(){
  # MAX-1515 re-review, finding F1b: $setup_rc (set by sync.sh right before calling this,
  # unset/0 for every caller that doesn't - e.g. a test sourcing this file standalone, which
  # keeps today's behaviour) is complete_setup's own status THIS cycle, and it is authoritative
  # over the team_is_protected re-check a few lines below: a 3 means THIS cycle's own
  # reconfigure attempt wrote real config into team/ and then failed partway, exactly the state
  # finding F1a closes a blind spot in. Checked first, never overridden by what that re-check
  # says on its own.
  if [ "${setup_rc:-0}" -eq 3 ]; then
    log "team folder configuration failed this cycle (complete_setup exit 3); skipping this cycle's team folder operations"
    return 2
  fi
  # MAX-1515 review, "also check": same symlink gap as sync_mirror - `-d "$TEAM/.git"` follows
  # a symlink, so check `-L` first, before anything else runs.
  if [ -L "$TEAM" ]; then
    log "the team folder is a symlink; refusing to touch it"
    return 1
  fi
  [ -d "$TEAM/.git" ] || return 0
  if ! remote_matches_expected "$TEAM" "$EXPECTED_TEAM_REMOTE"; then
    log "team origin does not match the expected remote; refusing to touch it"
    return 1
  fi
  # MAX-1515 review, finding C: an origin match alone is not proof team/ is actually protected
  # (sparse-checkout, hooks, hooksPath, symlinks) - complete_setup's own configure step can
  # fail (status 3) and a caller that discards that failure must not then commit into what is
  # still an unprotected clone. team_is_protected (lib/complete_setup.sh) re-derives the real
  # state; this cycle skips team/ entirely rather than trusting a marker or an origin match.
  if ! team_is_protected "$TEAM"; then
    log "team folder configuration is not complete; skipping this cycle"
    return 2
  fi
  cd "$TEAM" || return 1
  local big secret rc=0
  local -a exclude_specs=()
  local spec
  while IFS= read -r spec; do exclude_specs+=("$spec"); done < <(team_add_exclude_pathspecs)
  git add -A -- . "${exclude_specs[@]}" || { log "git add failed"; return 1; }
  while IFS= read -r -d '' big; do
    log "REJECT oversized: ${big#./}"
    git reset -q -- "$big" || rc=1
  done < <(find . -path ./.git -prune -o -type f -size +10240k -print0 2>/dev/null)
  [ "$rc" -eq 0 ] || return 1
  rm -f "$STATE/secret_rejects"
  while IFS= read -r -d '' secret; do
    if secret_scan_file "$secret"; then
      log "REJECT secret: $secret"
      git reset -q -- "$secret" || rc=1
      printf '%s\n' "$secret" >> "$STATE/secret_rejects"
    fi
  done < <(git diff --cached --name-only -z)
  [ "$rc" -eq 0 ] || return 1
  if ! git diff --cached --quiet; then
    GIT_AUTHOR_NAME="$GIT_IDENTITY_NAME" GIT_AUTHOR_EMAIL="$GIT_IDENTITY_EMAIL" \
      GIT_COMMITTER_NAME="$GIT_IDENTITY_NAME" GIT_COMMITTER_EMAIL="$GIT_IDENTITY_EMAIL" \
      git commit -qm "notes $(date -u +%F' '%T)Z" || return 1
  fi
}

# AC-6: local-only, and runs before online() - a down network can never hide unsynced work.
# The ONE place unsynced local work is measured. Both stale_check and the marker call it -
# they used to compute it separately, which made the marker immune to a defect in stale_check.
# Echoes the age in whole hours, or nothing when there is no unsynced work.
unsynced_age_hours(){
  [ -d "$TEAM/.git" ] || return 0
  local ahead oldest
  ahead=$(cd "$TEAM" && git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
  [ "$ahead" -gt 0 ] || return 0
  oldest=$(cd "$TEAM" && git log --format=%ct origin/main..HEAD | tail -1)
  echo $(( ($(date +%s) - oldest) / 3600 ))
}

# AC-6: local-only, and runs before online() - a down network can never hide unsynced work.
stale_check(){
  local age_h; age_h=$(unsynced_age_hours)
  [ -n "$age_h" ] || return 0
  if [ "$age_h" -ge "$STALE_HOURS" ]; then
    log "unsynced work ${age_h}h old; raising marker"
  fi
  return 0
}

# AC-6: saves the incoming (origin/main) version of every file the rebase could not merge
# automatically, so both copies exist on this Mac even though the local one wins on disk.
# During a rebase ":2:<path>" is the base being rebased onto (origin/main) - the reverse of a
# plain merge, where :2: would be "ours".
save_conflict_copies(){
  local ts; ts=$(date -u +%FT%TZ)
  local path dest
  while IFS= read -r -d '' path; do
    dest="$CONFLICTS/$ts/$path"
    mkdir -p "$(dirname "$dest")"
    git show ":2:$path" > "$dest" 2>/dev/null || git show "origin/main:$path" > "$dest" 2>/dev/null
    log "conflict: saved incoming copy of $path"
  done < <(git diff --name-only -z --diff-filter=U)
}

sync_team(){
  # MAX-1515 re-review, finding F1b: same $setup_rc check as commit_local above, checked first
  # for the same reason - see its comment there. No separate log line: commit_local already ran
  # (and logged) earlier in the same cycle whenever this matters.
  if [ "${setup_rc:-0}" -eq 3 ]; then
    return 2
  fi
  # MAX-1515 review, "also check": same symlink gap as commit_local/sync_mirror.
  if [ -L "$TEAM" ]; then
    log "the team folder is a symlink; refusing to touch it"
    return 1
  fi
  [ -d "$TEAM/.git" ] || return 0
  if ! remote_matches_expected "$TEAM" "$EXPECTED_TEAM_REMOTE"; then
    log "team origin does not match the expected remote; refusing to touch it"
    return 1
  fi
  # MAX-1515 review, finding C: never fetch/rebase/push into a team/ that matches the expected
  # origin but was never actually protected (sparse-checkout/hooks) - a colleague's push could
  # otherwise materialize instruction files straight onto disk through the rebase below.
  if ! team_is_protected "$TEAM"; then
    log "team folder configuration is not complete; skipping this cycle"
    return 2
  fi
  cd "$TEAM" || return 1
  local n
  n=$(cat "$CONFLICT_STATE" 2>/dev/null || echo 0)
  if [ "$n" -ge "$MAX_CONFLICT_ATTEMPTS" ]; then   # AC-5: bounded, named constant
    log "conflict unresolved after $n attempts; not retrying until a human intervenes"
    return 3
  fi
  git fetch --quiet origin || { log "team fetch failed (offline?)"; return 1; }
  if ! git rebase --quiet origin/main 2>>"$LOG"; then
    save_conflict_copies
    git rebase --abort 2>/dev/null || true
    echo $((n+1)) > "$CONFLICT_STATE"
    log "CONFLICT parked (attempt $((n+1))/$MAX_CONFLICT_ATTEMPTS); local content retained"
    return 3
  fi
  rm -f "$CONFLICT_STATE"
  local fetch_url push_url
  fetch_url=$(git remote get-url origin 2>/dev/null) || { log "team remote missing"; return 1; }
  while IFS= read -r push_url; do
    if [ "$push_url" != "$fetch_url" ]; then
      log "team push URL does not match fetch URL; refusing push"
      return 1
    fi
  done < <(git remote get-url --push --all origin 2>/dev/null)
  git push --quiet origin main 2>>"$LOG" || { log "push failed"; return 1; }
  log "team at $(git rev-parse --short HEAD)"
}

update_attention_marker(){
  local big age_h secret_first
  # fix 4b: an origin mismatch is worth telling a human about even before the other, more
  # common conditions below - it means this repo was touched by something other than setup.sh.
  if [ -d "$MIRROR/.git" ] && ! remote_matches_expected "$MIRROR" "$EXPECTED_MIRROR_REMOTE"; then
    printf 'The company folder is not connected to where it should be.\nNothing in it was changed this time. Please tell Max.\n' > "$MARK"
    return
  fi
  if [ -d "$TEAM/.git" ] && ! remote_matches_expected "$TEAM" "$EXPECTED_TEAM_REMOTE"; then
    printf 'The team folder is not connected to where it should be.\nYour notes are safe on this Mac, unchanged. Please tell Max.\n' > "$MARK"
    return
  fi
  if [ -d "$TEAM/.git" ]; then
    big=$(find "$TEAM" -path "$TEAM/.git" -prune -o -type f -size +10240k -print 2>/dev/null | head -1)
    if [ -n "$big" ]; then
      printf 'A file is too big to share and was left out:\n  %s\n' "${big#"$TEAM"/}" > "$MARK"
      return
    fi
    if [ -s "$STATE/secret_rejects" ]; then
      secret_first=$(head -1 "$STATE/secret_rejects")
      printf 'A file looked like it contained a password or access key, so it was kept out of the team folder:\n  %s\nIt is still on this Mac, unchanged. Please tell Max.\n' "$secret_first" > "$MARK"
      return
    fi
    if [ -f "$CONFLICT_STATE" ] && [ "$(cat "$CONFLICT_STATE")" -gt 0 ]; then
      printf 'A page in the team folder was changed by you and by a colleague at the same time.\nYour version is safe on this Mac.\nPlease tell Max.\n' > "$MARK"
      return
    fi
    age_h=$(unsynced_age_hours)
    if [ -n "$age_h" ] && [ "$age_h" -ge "$STALE_HOURS" ]; then
      printf 'Your notes have not reached the team for %s hours.\nYour work is safe on this Mac. Nothing was lost.\nPlease tell Max.\n' "$age_h" > "$MARK"
      return
    fi
  fi
  # MAX-1515 change A: setup itself (the team clone + its configuration, and the mirror clone -
  # see lib/complete_setup.sh) can sit pending for a while waiting on a deploy key Max has not
  # registered yet. Plain words, no git vocabulary - this can fire before team/ even exists.
  if [ ! -f "$STATE/setup-complete" ]; then
    local started elapsed_h
    started=$(cat "$STATE/setup-started" 2>/dev/null || true)
    if [ -n "$started" ]; then
      elapsed_h=$(( ($(date +%s) - started) / 3600 ))
      if [ "$elapsed_h" -ge "$SETUP_PENDING_ALERT_HOURS" ]; then
        printf 'Your Serlinolab folders are not ready yet.\nMax may still need to approve this Mac.\nNothing is lost.\nPlease tell Max.\n' > "$MARK"
        return
      fi
    fi
  fi
  rm -f "$MARK"
}

what_changed(){
  [ -d "$MIRROR/.git" ] || return 0   # not inside the mirror - clean would delete it
  { echo "# What changed"; echo
    git -C "$MIRROR" log -30 --date=short --pretty='- **%ad** %an - %s'
  } > "$ROOT/what-changed.md"
}
