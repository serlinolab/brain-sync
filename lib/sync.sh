#!/bin/bash
# Mirror sync, team sync, staleness, and the company README. Sourced by sync.sh.

online(){ git ls-remote --exit-code "$ONLINE_CHECK_REMOTE" HEAD >/dev/null 2>&1; }

# AC-2: files AND directories refuse writes - a stray new file can't be silently eaten by the next clean.
protect_readonly(){
  local dir="$1"
  find "$dir" -path "$dir/.git" -prune -o \( -type f -o -type d \) -exec chmod a-w {} + 2>/dev/null || true
}

# AC-8/AC-4: no git vocabulary in here. Regenerated every cycle since `git clean` would
# otherwise delete it (untracked). MAX-1515: "your personal folder next door" is gone - the
# mirror now lives nested inside team/, one level up from the mirror itself, not beside it.
company_readme(){
  cat > "$MIRROR/READ ME FIRST.txt" <<'TXT'
This folder is the company's shared knowledge. It updates on its own -
you don't need to do anything to keep it current.

You cannot add, change, or remove anything in here. That is on purpose,
so everyone always sees the same version.

Have something to add or correct? Save it in the team folder, one level
up, or tell Max directly.
TXT
}

# AC-4 (second layer): claudeMdExcludes names the team ROOT's instruction files only - never
# a glob like team/**/CLAUDE.md, which would also exclude the brand's own CLAUDE.md right
# here. Regenerated every cycle for the same reason as company_readme (git clean removes it),
# except when the mirror itself already tracks this path - then we never overwrite it.
mirror_settings_local(){
  if git -C "$MIRROR" ls-files --error-unmatch .claude/settings.local.json >/dev/null 2>&1; then
    log "mirror tracks .claude/settings.local.json; not overwriting"
    return 0
  fi
  mkdir -p "$MIRROR/.claude"
  cat > "$MIRROR/.claude/settings.local.json" <<JSON
{
  "claudeMdExcludes": [
    "$TEAM/CLAUDE.md",
    "$TEAM/CLAUDE.local.md",
    "$TEAM/AGENTS.md"
  ]
}
JSON
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
  [ "$rc" -eq 0 ] && mirror_settings_local || rc=1
  protect_readonly "$MIRROR"
  [ "$rc" -eq 0 ] && log "mirror at $(git -C "$MIRROR" rev-parse --short HEAD)"
  return "$rc"
}

# Class A #3: team/serlinolab must always be the real mirror clone - never a file, a symlink,
# or a directory that isn't backed by its own .git. Anything else has no legitimate reason to
# be there (a colleague's push can't put it there either - non-cone sparse-checkout refuses
# to check `serlinolab` out at team root, see write_team_sparse_checkout). Quarantined, never
# deleted; sync_mirror finding no .git there re-clones on the next cycle.
guard_mirror_slot(){
  [ -e "$MIRROR" ] || return 0
  if [ -L "$MIRROR" ] || [ ! -d "$MIRROR" ] || ! git -C "$MIRROR" rev-parse --git-dir >/dev/null 2>&1; then
    local ts dest; ts=$(date -u +%FT%TZ); dest="$QUARANTINE/$ts/serlinolab"
    mkdir -p "$(dirname "$dest")"
    mv "$MIRROR" "$dest"
    log "quarantined invalid mirror slot at serlinolab (not a real clone) - it will be re-cloned"
  fi
}

# AC-4 / Class A: move any locally-created CLAUDE.md / CLAUDE.local.md / AGENTS.md / .claude
# anywhere under team/ - excluding team/serlinolab, which is the brand's own and stays - into
# quarantine. Never deleted. Matched case-insensitively (APFS is case-insensitive: claude.md,
# Agents.MD reach the same place a differently-cased name would), and -iname's default
# no-follow behaviour means a symlink named one of these is quarantined as a link, never
# dereferenced. Also quarantines any OTHER symlink under team/ (outside the mirror) whose
# target resolves into the mirror or anywhere outside team/ - a colleague has no legitimate
# reason to commit such a link, and one materialising here could only be locally created (the
# sparse-checkout keeps a colleague's own symlink from ever checking out in the first place).
#
# Called BEFORE staging (so before anything else in the cycle) AND again after sync_team, on
# every path - success, conflict-abort, and failure alike - because a rebase can occasionally
# materialise a path the sparse-checkout would otherwise have refused to check out.
quarantine_instructions(){
  [ -d "$TEAM" ] || return 0
  guard_mirror_slot
  local ts; ts=$(date -u +%FT%TZ)
  local f rel dest target realtarget
  while IFS= read -r -d '' f; do
    rel="${f#"$TEAM"/}"
    dest="$QUARANTINE/$ts/$rel"
    mkdir -p "$(dirname "$dest")"
    mv "$f" "$dest"
    log "quarantined instruction file: $rel"
  done < <(find "$TEAM" \
             \( -path "$TEAM/.git" -o -path "$MIRROR" \) -prune -o \
             \( -iname 'CLAUDE.md' -o -iname 'CLAUDE.local.md' -o -iname 'AGENTS.md' -o -iname '.claude' \) -print0 \
             2>/dev/null)
  while IFS= read -r -d '' f; do
    rel="${f#"$TEAM"/}"
    target=$(readlink "$f" 2>/dev/null) || continue
    realtarget=$(cd "$(dirname "$f")" 2>/dev/null && realpath -q -- "$target" 2>/dev/null)
    # Legitimate iff the symlink resolves to somewhere under team/ that is NOT the mirror.
    # Anything else - resolves into the mirror, resolves outside team/ entirely, or could not
    # be resolved at all (dangling) - gets quarantined.
    case "$realtarget" in
      "$MIRROR"|"$MIRROR"/*) ;;
      "$TEAM"/*) continue ;;
      *) ;;
    esac
    dest="$QUARANTINE/$ts/$rel"
    mkdir -p "$(dirname "$dest")"
    mv "$f" "$dest"
    log "quarantined escaping symlink: $rel -> $target"
  done < <(find "$TEAM" \
             \( -path "$TEAM/.git" -o -path "$MIRROR" \) -prune -o \
             -type l -print0 2>/dev/null)
  return 0
}

# AC-3/AC-7: a restore point exists before any network call; rejects an oversized file, and a
# file that looks like it holds a secret, before either is ever staged. Neither rejection
# blocks the rest of the cycle - every other staged file still commits.
commit_local(){
  [ -d "$TEAM/.git" ] || return 0
  cd "$TEAM" || return 1
  local big secret rc=0
  git add -A || { log "git add failed"; return 1; }
  while IFS= read -r -d '' big; do
    log "REJECT oversized: ${big#./}"
    git reset -q -- "$big" || rc=1
  done < <(find . \( -path ./.git -o -path ./serlinolab \) -prune -o -type f -size +10240k -print0 2>/dev/null)
  [ "$rc" -eq 0 ] || return 1
  rm -f "$STATE/secret_rejects"
  while IFS= read -r -d '' secret; do
    if secret_scan_file "$secret"; then
      log "REJECT secret: $secret"
      git reset -q -- "$secret" || rc=1
      printf '%s\n' "$secret" >> "$STATE/secret_rejects"
    fi
  done < <(git diff --cached --name-only -z -- . ':!serlinolab')
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
  [ -d "$TEAM/.git" ] || return 0
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
  if [ -d "$TEAM/.git" ]; then
    big=$(find "$TEAM" \( -path "$TEAM/.git" -o -path "$MIRROR" \) -prune -o -type f -size +10240k -print 2>/dev/null | head -1)
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
  rm -f "$MARK"
}

what_changed(){
  [ -d "$MIRROR/.git" ] || return 0   # not inside the mirror - clean would delete it
  { echo "# What changed"; echo
    git -C "$MIRROR" log -30 --date=short --pretty='- **%ad** %an - %s'
  } > "$ROOT/what-changed.md"
}
