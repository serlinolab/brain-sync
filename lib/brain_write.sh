#!/bin/bash
# MAX-1790: the Brain as a two-way folder. Sourced by lib/sync.sh.
#
# Each cycle sync_mirror (lib/sync.sh) asks GitHub whether THIS Mac's deploy key may push to
# Serlinolab-Brain. Not writable (every Mac until Max upgrades its key, and again if he turns
# it back to read-only): the old read-only mirror, with one addition - anything a person had
# written meanwhile is copied to .state/brain-unsent first. Writable: the same pipeline team/
# uses, on the Brain, except that protected paths (lib/protected_paths.sh) are never committed.
# The GitHub push ruleset refuses those server-side; this is the engine's own layer.
_BRAIN_WRITE_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/protected_paths.sh
source "$_BRAIN_WRITE_LIBDIR/protected_paths.sh"
BRAIN_SIGNPOST="READ ME FIRST.txt"

# 0 this key can push, 1 it is read-only, 2 cannot tell. A dry run still authenticates against
# receive-pack, which is where GitHub refuses a read-only deploy key; it sends nothing. A
# "rejected" push (origin moved since the fetch a moment ago) got that far, so the key can write.
# Needs a fresh origin/main - the caller has just fetched.
brain_probe_push(){
  local out
  out=$(git -C "$MIRROR" push --dry-run --quiet origin refs/remotes/origin/main:refs/heads/main 2>&1) && return 0
  case "$out" in
    *rejected*|*"fetch first"*|*non-fast-forward*) return 0 ;;
    *"read only"*|*"read-only"*|*"denied to"*|*"Permission denied"*) return 1 ;;
  esac
  return 2
}

# A fresh folder under $1 named by the time (and made unique), for text that must not be lost.
_brain_keep_dir(){
  local d="$1/$(date -u +%FT%TZ)"
  [ -e "$d" ] && d="$d.$$"
  mkdir -p "$d" && printf '%s' "$d"
}

# Protected files and directories lose their write bit, everything else stays writable. Files are
# listed by git (tracked), directories by find; both judged by brain_path_protected.
brain_lock_protected(){
  local -a specs=()
  local s d
  while IFS= read -r s; do specs+=("${s/exclude,/}"); done < <(brain_protected_excludes)
  git -C "$MIRROR" ls-files -z -- "${specs[@]}" 2>/dev/null | (cd "$MIRROR" && xargs -0 chmod a-w 2>/dev/null)
  while IFS= read -r -d '' d; do
    [ "$d" = "$MIRROR" ] && continue
    brain_path_protected "${d#"$MIRROR"/}" && chmod a-w "$d" 2>/dev/null
  done < <(find "$MIRROR" -path "$MIRROR/.git" -prune -o -type d -print0 2>/dev/null)
  return 0
}

# cwd = $MIRROR. A protected path that changed (edited, created, deleted) is copied, if it still
# exists, to .state/protected-edits/<time>/<path>, then put back to what HEAD has (removed if HEAD
# has nothing). Runs before staging, so a protected path never reaches a commit.
brain_keep_protected_edits(){
  local p dest=""
  while IFS= read -r -d '' p; do
    brain_path_protected "$p" || continue
    if [ -e "$p" ] || [ -L "$p" ]; then
      [ -n "$dest" ] || dest=$(_brain_keep_dir "$BRAIN_PROTECTED_EDITS")
      mkdir -p "$dest/$(dirname "$p")" && cp -RP -- "$p" "$dest/$p"
    fi
    if git cat-file -e "HEAD:$p" 2>/dev/null; then
      git checkout -q HEAD -- "$p"
    else
      git rm -q -f --cached --ignore-unmatch -- "$p" >/dev/null 2>&1
      rm -rf -- "$p"; rmdir -p "$(dirname "$p")" 2>/dev/null
    fi
    log "protected Brain file changed, not shared: $p (${dest:+kept in $dest, }put back)"
  done < <(git diff --name-only -z --no-renames HEAD --; git ls-files -o --exclude-standard -z)
  return 0
}

commit_brain(){
  [ -e "$BRAIN_WRITABLE" ] || return 0   # set by the last sync_mirror probe; no network here
  if [ -L "$MIRROR" ]; then log "the company folder is a symlink; refusing to touch it"; return 1; fi
  [ -d "$MIRROR/.git" ] || return 0
  if ! remote_matches_expected "$MIRROR" "$EXPECTED_MIRROR_REMOTE"; then
    log "mirror origin does not match the expected remote; refusing to touch it"
    return 1
  fi
  local rc=0
  chmod -R u+w "$MIRROR" 2>/dev/null || true
  cd "$MIRROR" || return 1
  brain_keep_protected_edits
  _commit_repo "$MIRROR" brain || rc=$?
  brain_lock_protected
  return "$rc"
}

# Writing was switched off again (or never on): save what a person left in the folder before
# the reset below erases it - uncommitted edits, new files, and commits that never got pushed.
# Protected paths are not kept here (they are never the person's to send).
brain_preserve_unsent(){
  local list dest="" p n=0
  list=$(mktemp) || return 0
  { git -C "$MIRROR" diff --name-only -z --no-renames origin/main --
    git -C "$MIRROR" ls-files -o --exclude-standard -z; } > "$list" 2>/dev/null
  while IFS= read -r -d '' p; do
    brain_path_protected "$p" && continue
    [ "$p" = "$BRAIN_SIGNPOST" ] && continue
    [ -e "$MIRROR/$p" ] || [ -L "$MIRROR/$p" ] || continue
    [ -n "$dest" ] || dest=$(_brain_keep_dir "$BRAIN_UNSENT") || break
    mkdir -p "$dest/files/$(dirname "$p")" && cp -RP -- "$MIRROR/$p" "$dest/files/$p" && n=$((n+1))
  done < "$list"
  rm -f "$list"
  [ "$n" -gt 0 ] || return 0
  local -a ex=()
  while IFS= read -r p; do ex+=("$p"); done < <(brain_protected_excludes)
  git -C "$MIRROR" diff --binary origin/main -- . "${ex[@]}" > "$dest/changes.patch" 2>/dev/null
  log "this Mac can no longer write to the Brain; $n unsent file(s) kept in $dest"
}

# The push step's hook (lib/sync.sh, _sync_after_fetch). "gate": 0 go ahead, 1 skip as a failure
# (GitHub already refused these exact commits), 2 skip, nothing to send. "refused <push output>":
# if the ruleset refused protected paths in our own commits, keep their text, rebuild the commits
# without them and return 0 (the caller pushes once more); anything else returns 1. Either way the
# state is recorded, so the same refused commits are never pushed again.
brain_push_hook(){
  local origin_sha local_sha p dest=""
  origin_sha=$(git rev-parse origin/main 2>/dev/null); local_sha=$(git rev-parse HEAD 2>/dev/null)
  if [ "$1" = gate ]; then
    [ "$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)" -gt 0 ] || { rm -f "$BRAIN_PUSH_PARKED"; return 2; }
    if [ "$(cat "$BRAIN_PUSH_PARKED" 2>/dev/null)" = "$origin_sha $local_sha" ]; then
      log "GitHub refused these Brain commits and nothing has changed; not pushing them again"
      return 1
    fi
    return 0
  fi
  case "$2" in *GH013*|*"repository rule violations"*|*"File path is restricted"*) ;; *) return 1 ;; esac
  echo "$origin_sha $local_sha" > "$BRAIN_PUSH_PARKED"
  local -a prot=()
  while IFS= read -r -d '' p; do brain_path_protected "$p" && prot+=("$p"); done < <(git diff --name-only -z --no-renames origin/main HEAD --)
  [ "${#prot[@]}" -gt 0 ] || { log "GitHub refused the Brain push but none of our changes touch a protected path; parked"; return 1; }
  dest=$(_brain_keep_dir "$BRAIN_PROTECTED_EDITS") || return 1
  for p in "${prot[@]}"; do
    if git cat-file -e "HEAD:$p" 2>/dev/null; then
      mkdir -p "$dest/$(dirname "$p")" && git show "HEAD:$p" > "$dest/$p"
    fi
  done
  git reset -q --soft origin/main || return 1
  for p in "${prot[@]}"; do
    if git cat-file -e "origin/main:$p" 2>/dev/null; then git checkout -q origin/main -- "$p"
    else git rm -q -f --cached --ignore-unmatch -- "$p" >/dev/null 2>&1; rm -rf -- "$p"; fi
  done
  git diff --cached --quiet || _commit_as_person "notes $(date -u +%F' '%T)Z" || return 1
  log "GitHub refused protected Brain paths (${prot[*]}); kept their text in $dest and sent the rest"
  echo "$origin_sha $(git rev-parse HEAD)" > "$BRAIN_PUSH_PARKED"
}

# Writable mode of sync_mirror, right after its fetch.
_sync_brain_two_way(){
  local CONFLICTS_DIR="$BRAIN_CONFLICTS" NOTE_PREFIX="Serlinolab_Brain/" rc=0
  [ -e "$BRAIN_WRITABLE" ] || log "this Mac may now write to the Brain; the folder is editable"
  : > "$BRAIN_WRITABLE"
  chmod -R u+w "$MIRROR" 2>/dev/null || true   # protected paths were read-only; git must replace them
  git -C "$MIRROR" config core.hooksPath "$MIRROR/.git/hooks"
  install_team_hooks "$MIRROR" "$STATE/engine/lib" || log "could not install the secret-scan hooks in the Brain"
  _sync_after_fetch "$MIRROR" brain "$BRAIN_CONFLICT_STATE" "$BRAIN_CONFLICT_PARK_SHAS" "$BRAIN_AUTOSTASH_STATE" brain_push_hook || rc=$?
  company_readme writable
  brain_lock_protected
  chmod a-w "$MIRROR/$BRAIN_SIGNPOST" 2>/dev/null
  return "$rc"
}

# update_attention_marker's part for the Brain; 0 = it wrote $MARK. Everything is re-derived
# from state files / folders, like the team's, so it clears itself.
brain_attention(){
  [ -d "$MIRROR/.git" ] || return 1
  local f age_h d
  if [ -s "$STATE/brain_oversized_rejects" ]; then
    printf 'A file in the Serlinolab_Brain folder is too big to share and was left out:\n  %s\n' "$(head -1 "$STATE/brain_oversized_rejects")" > "$MARK"; return 0
  fi
  if [ -s "$STATE/brain_secret_rejects" ]; then
    printf 'A file looked like it contained a password or access key, so it was kept out of the Serlinolab_Brain folder:\n  %s\nIt is still on this Mac, unchanged. Please tell Max.\n' "$(head -1 "$STATE/brain_secret_rejects")" > "$MARK"; return 0
  fi
  if [ -f "$BRAIN_AUTOSTASH_STATE" ]; then
    if [ -n "$(git -C "$MIRROR" stash list 2>/dev/null)" ]; then
      printf 'Some of your changes in the Serlinolab_Brain folder could not be automatically reapplied after the last update and are waiting safely in a hidden spot on this Mac.\nNothing was lost - please tell Max so this Mac can be fixed.\n' > "$MARK"; return 0
    fi
    rm -f "$BRAIN_AUTOSTASH_STATE"
  fi
  if [ -f "$BRAIN_CONFLICT_STATE" ] && [ "$(cat "$BRAIN_CONFLICT_STATE")" -gt 0 ]; then
    printf 'A page in the Serlinolab_Brain folder was changed by you and by a colleague at the same time.\nYour version is safe on this Mac.\nPlease tell Max.\n' > "$MARK"; return 0
  fi
  age_h=$(unsynced_age_hours "$MIRROR")
  if [ -n "$age_h" ] && [ "$age_h" -ge "$STALE_HOURS" ]; then
    printf 'Your changes in the Serlinolab_Brain folder have not reached the team for %s hours.\nYour work is safe on this Mac. Nothing was lost.\nPlease tell Max.\n' "$age_h" > "$MARK"; return 0
  fi
  d=$(find "$BRAIN_PROTECTED_EDITS" -mindepth 1 -maxdepth 1 -type d -mmin "-$BRAIN_NOTICE_MINUTES" 2>/dev/null | sort | tail -1)
  if [ -n "$d" ]; then
    printf 'You changed a locked page in the Serlinolab_Brain folder (the rules, the skills, the method folder, or a page that updates itself). That change was not shared.\nYour text is kept here:\n  %s\n' "$d" > "$MARK"; return 0
  fi
  d=$(find "$BRAIN_UNSENT" -mindepth 1 -maxdepth 1 -type d -mmin "-$BRAIN_NOTICE_MINUTES" 2>/dev/null | sort | tail -1)
  if [ -n "$d" ]; then
    printf 'This Mac can no longer change the Serlinolab_Brain folder, so your latest changes there were not shared.\nYour text is kept here:\n  %s\nPlease tell Max.\n' "$d" > "$MARK"; return 0
  fi
  return 1
}
