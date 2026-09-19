#!/bin/bash
# Mirror sync, personal sync, staleness, and the company README. Sourced by sync.sh.

online(){ git ls-remote --exit-code "$ONLINE_CHECK_REMOTE" HEAD >/dev/null 2>&1; }

# AC-2: files AND directories refuse writes - a stray new file can't be silently eaten by the next clean.
protect_readonly(){
  local dir="$1"
  find "$dir" -path "$dir/.git" -prune -o \( -type f -o -type d \) -exec chmod a-w {} + 2>/dev/null || true
}

# AC-8: no git vocabulary in here. Regenerated every cycle since `git clean` would otherwise delete it (untracked).
company_readme(){
  cat > "$MIRROR/READ ME FIRST.txt" <<'TXT'
This folder is the company's shared knowledge. It updates on its own -
you don't need to do anything to keep it current.

You cannot add, change, or remove anything in here. That is on purpose,
so everyone always sees the same version.

Have something to add or correct? Put a note in your personal folder
next door, or tell Max directly.
TXT
}

sync_mirror(){
  [ -d "$MIRROR/.git" ] || return 0
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

# AC-3: a restore point exists before any network call; also rejects an oversized file before it's ever staged.
commit_local(){
  [ -d "$PERSONAL/.git" ] || return 0
  cd "$PERSONAL" || return 1
  local big rc=0
  git add -A || { log "git add failed"; return 1; }
  while IFS= read -r -d '' big; do
    log "REJECT oversized: ${big#./}"
    git reset -q -- "$big" || rc=1
  done < <(find . -path ./.git -prune -o -type f -size +10240k -print0 2>/dev/null)
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
  [ -d "$PERSONAL/.git" ] || return 0
  local ahead oldest
  ahead=$(cd "$PERSONAL" && git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
  [ "$ahead" -gt 0 ] || return 0
  oldest=$(cd "$PERSONAL" && git log --format=%ct origin/main..HEAD | tail -1)
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


sync_personal(){
  [ -d "$PERSONAL/.git" ] || return 0
  cd "$PERSONAL" || return 1
  local n
  n=$(cat "$CONFLICT_STATE" 2>/dev/null || echo 0)
  if [ "$n" -ge "$MAX_CONFLICT_ATTEMPTS" ]; then   # AC-5: bounded, named constant
    log "conflict unresolved after $n attempts; not retrying until a human intervenes"
    return 3
  fi
  git fetch --quiet origin || { log "personal fetch failed (offline?)"; return 1; }
  if ! git rebase --quiet origin/main 2>>"$LOG"; then
    git rebase --abort 2>/dev/null || true
    echo $((n+1)) > "$CONFLICT_STATE"
    log "CONFLICT parked (attempt $((n+1))/$MAX_CONFLICT_ATTEMPTS); local content retained"
    return 3
  fi
  rm -f "$CONFLICT_STATE"
  git push --quiet origin main 2>>"$LOG" || { log "push failed"; return 1; }
  log "personal at $(git rev-parse --short HEAD)"
}

update_attention_marker(){
  local big age_h
  if [ -d "$PERSONAL/.git" ]; then
    big=$(find "$PERSONAL" -path "$PERSONAL/.git" -prune -o -type f -size +10240k -print 2>/dev/null | head -1)
    if [ -n "$big" ]; then
      printf 'A file is too big to share and was left out:\n  %s\n' "${big#"$PERSONAL/"}" > "$MARK"
      return
    fi
    if [ -f "$CONFLICT_STATE" ] && [ "$(cat "$CONFLICT_STATE")" -gt 0 ]; then
      printf 'Your notes have not reached the team.\nThey are stuck behind a conflict that could not be resolved automatically.\nYour work is safe on this Mac. Nothing was lost.\nPlease tell Max.\n' > "$MARK"
      return
    fi
    age_h=$(unsynced_age_hours)
    if [ -n "$age_h" ] && [ "$age_h" -ge "$STALE_HOURS" ]; then
      printf 'Your notes have not reached the team for %s hours.\nYour work is safe on this Mac. Nothing was lost.\nPlease tell Max.\n' "$age_h" > "$MARK"
      return
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
