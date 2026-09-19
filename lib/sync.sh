#!/bin/bash
# Mirror sync, personal sync, staleness, and the company README. Sourced by sync.sh.

online(){ git ls-remote --exit-code "$ONLINE_CHECK_REMOTE" HEAD >/dev/null 2>&1; }

# AC-2: files AND directories refuse writes - a stray new file can't be silently eaten by the next clean.
protect_readonly(){
  local dir="$1"
  find "$dir" -path "$dir/.git" -prune -o -type f -print0 2>/dev/null | xargs -0 chmod a-w 2>/dev/null || true
  find "$dir" -path "$dir/.git" -prune -o -type d -print0 2>/dev/null | xargs -0 chmod a-w 2>/dev/null || true
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
  chmod -R u+w "$MIRROR" 2>/dev/null || true   # git needs write to update its own files
  git -C "$MIRROR" fetch --quiet origin || { log "mirror fetch failed"; return 1; }
  git -C "$MIRROR" reset --hard --quiet origin/main
  git -C "$MIRROR" clean -ffdq
  company_readme
  protect_readonly "$MIRROR"
  log "mirror at $(git -C "$MIRROR" rev-parse --short HEAD)"
}

# AC-3: a restore point exists before any network call; also rejects an oversized file before it's ever staged.
commit_local(){
  [ -d "$PERSONAL/.git" ] || return 0
  cd "$PERSONAL" || return 1
  local big
  big=$(find . -path ./.git -prune -o -type f -size +10240k -print 2>/dev/null | head -1)
  if [ -n "$big" ]; then
    log "REJECT oversized: $big"
    printf 'A file is too big to share and was left out:\n  %s\n' "${big#./}" > "$MARK"
    return 2
  fi
  git add -A
  git diff --cached --quiet || git commit -qm "notes $(date -u +%F' '%T)Z"
}

# AC-6: local-only, and runs before online() - a down network can never hide unsynced work.
stale_check(){
  [ -d "$PERSONAL/.git" ] || return 0
  local ahead oldest age_h
  ahead=$(cd "$PERSONAL" && git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
  [ "$ahead" -gt 0 ] || return 0
  oldest=$(cd "$PERSONAL" && git log --format=%ct origin/main..HEAD | tail -1)
  age_h=$(( ($(date +%s) - oldest) / 3600 ))
  if [ "$age_h" -ge "$STALE_HOURS" ]; then
    log "unsynced work ${age_h}h old ($ahead commits); raising marker"
    printf 'Your notes have not reached the team for %s hours.\nYour work is safe on this Mac. Nothing was lost.\nPlease tell Max.\n' "$age_h" > "$MARK"
  fi
}

sync_personal(){
  [ -d "$PERSONAL/.git" ] || return 0
  cd "$PERSONAL" || return 1
  local n
  n=$(cat "$CONFLICT_STATE" 2>/dev/null || echo 0)
  if [ "$n" -ge "$MAX_CONFLICT_ATTEMPTS" ]; then   # AC-5: bounded, named constant
    log "conflict unresolved after $n attempts; not retrying until a human intervenes"
    printf 'Your notes have not reached the team.\nThey are stuck behind a conflict that could not be resolved automatically.\nYour work is safe on this Mac. Nothing was lost.\nPlease tell Max.\n' > "$MARK"
    return 3
  fi
  git fetch --quiet origin || { log "personal fetch failed (offline?)"; return 1; }
  if ! git rebase --quiet origin/main 2>>"$LOG"; then
    git rebase --abort 2>/dev/null || true
    echo $((n+1)) > "$CONFLICT_STATE"
    log "CONFLICT parked (attempt $((n+1))/$MAX_CONFLICT_ATTEMPTS); local content retained"
    printf 'Two versions of your notes disagree.\nYour copy is safe on this Mac - nothing was lost.\nIt has not reached the team yet.\n' > "$MARK"
    return 3
  fi
  rm -f "$CONFLICT_STATE"
  git push --quiet origin main 2>>"$LOG" || { log "push failed"; return 1; }
  rm -f "$MARK"     # AC-7: clear a stale claim once the condition it named is gone
  log "personal at $(git rev-parse --short HEAD)"
}

what_changed(){
  [ -d "$MIRROR/.git" ] || return 0   # not inside the mirror - clean would delete it
  { echo "# What changed"; echo
    git -C "$MIRROR" log -30 --date=short --pretty='- **%ad** %an - %s'
  } > "$ROOT/what-changed.md"
}
