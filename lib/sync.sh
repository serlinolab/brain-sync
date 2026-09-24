#!/bin/bash
# Mirror sync, team sync, staleness, and the company README. Sourced by sync.sh.

online(){ git ls-remote --exit-code "$ONLINE_CHECK_REMOTE" HEAD >/dev/null 2>&1; }

# Codex review of aea244e, blocking finding 1: ONLINE_CHECK_REMOTE (online() above) probes only
# the MIRROR's own remote - it defaults to EXPECTED_MIRROR_REMOTE, over the mirror's own deploy
# key. A single "offline" verdict from that ONE probe used to gate BOTH sync_mirror and
# sync_team, so a mirror-key-only outage (not yet registered, revoked, or the mirror host down)
# blocked team/ from syncing even though team/ has its own remote and its own key and was
# perfectly reachable - the exact shape of the MacBook Air's 13:26 "offline" log line during the
# 2026-09-24 incident. Probes team/'s ACTUAL configured origin when team/ exists (so a swapped
# or genuinely broken team remote is still caught for real); before team/ exists (still pending
# setup) falls back to the expected remote itself, so a brand-new Mac's very first cycles can
# tell "team key not registered yet" apart from "no network at all".
team_online(){
  local remote
  if [ -d "$TEAM/.git" ]; then
    remote=$(git -C "$TEAM" remote get-url origin 2>/dev/null) || return 1
  else
    remote="$EXPECTED_TEAM_REMOTE"
  fi
  git ls-remote --exit-code "$remote" HEAD >/dev/null 2>&1
}

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
  # 2026-09-24 incident: heal an already-set-up Mac too, not just a fresh clone -
  # complete_setup's write_team_exclude only ever runs once, at configure time, so an
  # already-protected team/ (team_is_protected true, complete_setup skipped entirely) would
  # otherwise never get it. Regenerating every cycle is one cheap file write.
  write_team_exclude "$TEAM" || { log "could not write the OS-junk exclude file"; return 1; }
  # Untrack any OS junk a colleague or an earlier version of this engine already committed -
  # the exclude file above only stops a NEW untracked file from being added; an already-
  # tracked one stays "modified" (and the tree "dirty") every time Finder rewrites it. Keeps
  # the file on disk, only drops it from git's index.
  local -a junk_specs=()
  local spec
  while IFS= read -r spec; do junk_specs+=("$spec"); done < <(team_os_junk_pathspecs)
  git rm -r --cached --ignore-unmatch -q -- "${junk_specs[@]}" >/dev/null 2>&1 || true
  local big secret rc=0
  local -a exclude_specs=()
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

# 2026-09-24 incident, root causes 1+4: heals a Mac whose LOCAL, not-yet-pushed commits
# already carry OS junk from before this fix existed (Finder rewriting .DS_Store between
# cycles, committed by the old commit_local). These commits were never pushed - origin/main is
# untouched by this, nothing is forced, nothing shared is rewritten. Drops the junk from every
# commit's tree in the unpushed range and prunes any commit left empty by that (one that ONLY
# ever touched .DS_Store); a commit that also carried a real note change keeps that change,
# junk stripped out of it. One `git log` once the backlog is clean, so safe to call every
# cycle. Prints 1 on stdout if it actually rewrote something, 0 otherwise.
heal_local_junk_history(){
  local team="$1"
  git -C "$team" rev-parse --verify -q origin/main >/dev/null 2>&1 || { echo 0; return 0; }
  local ahead; ahead=$(git -C "$team" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
  [ "$ahead" -gt 0 ] || { echo 0; return 0; }
  local -a specs=()
  local spec
  while IFS= read -r spec; do specs+=("$spec"); done < <(team_os_junk_pathspecs)
  local touched
  touched=$(git -C "$team" log --name-only --pretty=format: origin/main..HEAD -- "${specs[@]}" 2>/dev/null | sed '/^$/d')
  [ -n "$touched" ] || { echo 0; return 0; }
  log "rewriting $ahead unpushed local commit(s) to drop OS junk before it can reach the team"
  local filter_script
  filter_script=$(mktemp) || { echo 0; return 0; }
  {
    printf '#!/bin/bash\n'
    printf 'git rm -r --cached --ignore-unmatch -q --'
    local p
    for p in "${specs[@]}"; do printf ' %q' "$p"; done
    printf '\n'
  } > "$filter_script"
  chmod +x "$filter_script"
  rm -rf "$team/.git/refs/original"   # a stale backup ref from an earlier failed attempt
  if FILTER_BRANCH_SQUELCH_WARNING=1 git -C "$team" filter-branch -f --prune-empty \
       --index-filter "$filter_script" -- origin/main..HEAD >>"$LOG" 2>&1; then
    rm -rf "$team/.git/refs/original"
    rm -f "$filter_script"
    log "local history cleaned; real changes kept, junk dropped"
    echo 1
  else
    rm -f "$filter_script"
    log "could not clean local history of OS junk; leaving it for a human to look at"
    echo 0
  fi
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
  # Codex review of aea244e, blocking finding 2: fetch BEFORE healing - heal_local_junk_history
  # bounds its rewrite to `origin/main..HEAD`, and that has to be the FRESH origin/main, not
  # whatever this clone last knew (possibly long stale, or never fetched at all on a brand-new
  # clone). Healing against a stale origin/main could rewrite commits that are no longer ahead,
  # or miss ones that now are. If origin/main is still unknown after a successful fetch, this
  # cycle does not push at all.
  local fetch_err
  if ! fetch_err=$(git fetch --quiet origin 2>&1); then
    log "team fetch failed: ${fetch_err:-no error output}"
    return 1
  fi
  if ! git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    log "origin/main still unknown after fetch; not pushing this cycle"
    return 1
  fi
  # 2026-09-24 incident: clean any junk-only local history, now bounded by the fresh
  # origin/main above.
  local healed; healed=$(heal_local_junk_history "$TEAM")
  local n
  n=$(cat "$CONFLICT_STATE" 2>/dev/null || echo 0)
  local already_rebased=0
  # Codex re-review of 0b5862b: captured BEFORE either rebase attempt below - a stash that was
  # already sitting here for an unrelated reason (a person's own `git stash`, or an earlier
  # cycle's still-unresolved autostash conflict) must never block THIS push. Only a NEW entry -
  # one this cycle's own `--autostash` created and then failed to reapply - counts.
  local stash_before; stash_before=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
  if [ "$healed" = 1 ] && [ "$n" -ge "$MAX_CONFLICT_ATTEMPTS" ]; then
    # Codex review of aea244e, blocking finding 3: cleaning junk out of local history is not
    # proof the park itself was junk-caused - a genuine content conflict that also happened to
    # carry junk must stay parked. Only a real rebase attempt can tell the two apart, so
    # re-attempt it for real and let ITS outcome decide: success proves it was junk, clear the
    # latch and carry the already-rebased tree into the push below; failure proves a genuine
    # conflict (or something else) survives, so the latch is left exactly as it was - no
    # further attempt is spent probing it - and this cycle stays parked, same as before.
    if git rebase --quiet --autostash origin/main 2>>"$LOG"; then
      rm -f "$CONFLICT_STATE"
      log "cleared a parked conflict after cleaning local history of OS junk; rebase now succeeds cleanly"
      n=0
      already_rebased=1
    else
      save_conflict_copies
      git rebase --abort 2>/dev/null || true
      log "a park at the bound survives cleaning OS junk from local history - a genuine conflict remains; still not retrying until a human intervenes"
      return 3
    fi
  fi
  if [ "$n" -ge "$MAX_CONFLICT_ATTEMPTS" ]; then   # AC-5: bounded, named constant
    log "conflict unresolved after $n attempts; not retrying until a human intervenes"
    return 3
  fi
  if [ "$already_rebased" -eq 0 ]; then
    # --autostash: a dirty TRACKED file (historically .DS_Store, rewritten by Finder between
    # commit_local's commit and this rebase) is not a content conflict - it must never be
    # counted as one. autostash stashes it, rebases cleanly, and restores it after, so only a
    # real, unresolvable diff against origin/main ever reaches the branch below.
    if ! git rebase --quiet --autostash origin/main 2>>"$LOG"; then
      save_conflict_copies
      git rebase --abort 2>/dev/null || true
      echo $((n+1)) > "$CONFLICT_STATE"
      log "CONFLICT parked (attempt $((n+1))/$MAX_CONFLICT_ATTEMPTS); local content retained"
      return 3
    fi
  fi
  rm -f "$CONFLICT_STATE"
  # Codex review of aea244e, non-blocking finding 6 (tightened by the re-review of 0b5862b): a
  # rebase that succeeds can still leave the autostash NOT fully reapplied - if popping it
  # conflicts with the new HEAD, `git rebase --autostash` still exits 0 (only a warning is
  # printed) and leaves the stash entry behind instead of dropping it, with the working tree
  # possibly carrying unresolved conflict markers. Pushing (or letting the next commit_local
  # `git add -A` that) through would be silent corruption - refuse instead. Compared against
  # $stash_before (captured above, before either rebase attempt), not bare non-emptiness - an
  # unrelated pre-existing stash must never trip this or block the push.
  local stash_after; stash_after=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
  if [ "$stash_after" -gt "$stash_before" ]; then
    : > "$AUTOSTASH_CONFLICT_STATE"
    log "the autostash could not be reapplied cleanly after the rebase; local changes are preserved in 'git stash' - refusing to push until a human resolves this"
    return 1
  fi
  local fetch_url push_url
  fetch_url=$(git remote get-url origin 2>/dev/null) || { log "team remote missing"; return 1; }
  while IFS= read -r push_url; do
    if [ "$push_url" != "$fetch_url" ]; then
      log "team push URL does not match fetch URL; refusing push"
      return 1
    fi
  done < <(git remote get-url --push --all origin 2>/dev/null)
  local push_err
  if ! push_err=$(git push --quiet origin main 2>&1); then
    log "push failed: ${push_err:-no error output}"
    return 1
  fi
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
    # Codex re-review of 0b5862b: re-derived from the real stash list, not trusted as a
    # standing flag (AC-7) - if a human already ran `git stash pop`/`drop` and the stash is
    # genuinely gone, this clears itself and falls through to the checks below instead of
    # claiming a problem that no longer exists.
    if [ -f "$AUTOSTASH_CONFLICT_STATE" ]; then
      if [ -n "$(git -C "$TEAM" stash list 2>/dev/null)" ]; then
        printf 'Some of your local changes could not be automatically reapplied after the last update and are waiting safely in a hidden spot on this Mac.\nNothing was lost - please tell Max so this Mac can be fixed.\n' > "$MARK"
        return
      fi
      rm -f "$AUTOSTASH_CONFLICT_STATE"
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
