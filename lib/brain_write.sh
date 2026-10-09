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
# LC_ALL=C: the "rejected" / "fetch first" / "non-fast-forward" words are printed by the LOCAL git,
# which translates them (this Mac's prints Italian). The rest it matches is server text ("marked as
# read only", GH013 in brain_push_hook) or ssh's, which are never translated. Those two are the only
# places the engine reads a git message; everything else uses exit codes or porcelain/-z output.
brain_probe_push(){
  local out
  out=$(LC_ALL=C git -C "$MIRROR" push --dry-run --quiet origin refs/remotes/origin/main:refs/heads/main 2>&1) && return 0
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

# A copy of a person's Brain work could not be made. Whoever called this must not go on to
# restore / reset / clean: it logs, leaves a state file the attention marker reads (brain_attention),
# and returns 1. $1 is the reason, for the log.
_brain_preserve_fail(){
  log "could not keep a copy of work in the Brain folder ($1); changing nothing in it this cycle"
  printf '%s\n' "$1" > "$BRAIN_PRESERVE_FAILED" 2>/dev/null
  return 1
}

# Copy $MIRROR/$4 to <this run's folder>/$3$4. $1 = state folder the run's folder lives in, $2 = NAME of
# the variable holding this run's folder (made on first use), $3 = "" or "files/".
_brain_keep_one(){
  local d="${!2}"
  if [ -z "$d" ]; then d=$(_brain_keep_dir "$1") || return 1; printf -v "$2" '%s' "$d"; fi
  mkdir -p "$d/$3$(dirname "$4")" && cp -RP -- "$MIRROR/$4" "$d/$3$4"
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

# Protected paths are judged by brain_path_protected; `git add`'s exclusions only stop NEW staging, so
# anything already in the index at such a path has to be taken out of it explicitly. cwd = $MIRROR.
brain_unstage_protected(){
  local s
  local -a specs=()
  while IFS= read -r s; do specs+=("${s/exclude,/}"); done < <(brain_protected_excludes)
  git reset -q -- "${specs[@]}"
}

# cwd = $MIRROR. A protected path that changed (edited, created, deleted) is copied, if it still
# exists, to .state/protected-edits/<time>/<path>, then put back to what HEAD has (removed if HEAD
# has nothing). A protected path whose text exists only in the index (git add, then the file put back
# on disk) is saved the same way as .state/protected-edits/<time>/staged/<path>. Runs before staging, so
# a protected path never reaches a commit. ALL OR NOTHING: every
# copy is made first, and only when all of them worked is anything put back - one that fails leaves
# every protected path exactly as the person left it (the caller then stops the cycle) and returns 1.
brain_keep_protected_edits(){
  local p dest="" list
  local -a prot=()
  list=$(mktemp "${TMPDIR:-/tmp}/brain-list.XXXXXX") || { _brain_preserve_fail "no temporary file"; return 1; }
  { git diff --name-only -z --no-renames HEAD -- && git diff --cached --name-only -z --no-renames HEAD -- \
      && git ls-files -o --exclude-standard -z; } > "$list" 2>/dev/null \
    || { rm -f "$list"; _brain_preserve_fail "could not list what changed"; return 1; }
  while IFS= read -r -d '' p; do brain_path_protected "$p" && prot+=("$p"); done < <(sort -zu "$list")
  rm -f "$list"
  for p in ${prot[@]+"${prot[@]}"}; do
    if ! git diff --cached --quiet HEAD -- "$p" && git cat-file -e ":$p" 2>/dev/null; then   # staged text, whatever the disk says
      { [ -n "$dest" ] || dest=$(_brain_keep_dir "$BRAIN_PROTECTED_EDITS"); } \
        && mkdir -p "$dest/staged/$(dirname "$p")" && git show ":$p" > "$dest/staged/$p" \
        || { log "could not copy staged protected Brain file $p aside; changing none of them"; _brain_preserve_fail "a staged locked page could not be copied aside"; return 1; }
    fi
    [ -e "$p" ] || [ -L "$p" ] || continue
    _brain_keep_one "$BRAIN_PROTECTED_EDITS" dest "" "$p" \
      || { log "could not copy protected Brain file $p aside; changing none of them"; _brain_preserve_fail "a locked page could not be copied aside"; return 1; }
  done
  for p in ${prot[@]+"${prot[@]}"}; do
    if git cat-file -e "HEAD:$p" 2>/dev/null; then
      git checkout -q HEAD -- "$p"
    else
      git rm -q -f --cached --ignore-unmatch -- "$p" >/dev/null 2>&1
      rm -rf -- "$p"; rmdir -p "$(dirname "$p")" 2>/dev/null
    fi
    log "protected Brain file changed, not shared: $p (${dest:+kept in $dest, }put back)"
  done
  rm -f "$BRAIN_PRESERVE_FAILED"
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
  # 3: a copy failed. Nothing more happens to the Brain this cycle - no commit (a staged protected path
  # would go into it), and sync.sh keeps sync_mirror away from it (brain_hold) - so the folder stays as
  # the person left it and the notice (brain_attention) is true.
  if ! brain_keep_protected_edits; then brain_lock_protected; return 3; fi
  _commit_repo "$MIRROR" brain || rc=$?
  brain_lock_protected
  return "$rc"
}

# The Mac is read-only now (the key never could write, or was turned back to read-only) and the
# reset below would erase whatever a person left in the folder. Saved first, all measured against
# what THIS clone last had (HEAD) and what it had committed without pushing (origin/main..HEAD) - never
# against the origin that was just fetched, or a colleague's upstream change would look like the
# person's own:
#   - unprotected work (uncommitted edits, new files, unpushed commits) -> .state/brain-unsent/<time>/
#     files/<path> plus changes.patch;
#   - protected paths someone changed anyway (the lock was overridden) -> .state/protected-edits/<time>/<path>,
#     the same place and notice as in writable mode.
# An IGNORED local file (a global ignore such as *.local.md) is invisible to the measures here and to
# git's own overwrite checks, but a colleague who force-adds the same path upstream replaces it silently
# on reset or rebase. Before either, every ignored untracked file whose path the fetched origin/main
# tracks with different text is copied to .state/brain-replaced/<time>/<path>. OS junk is not kept.
# Needs a fresh origin/main. Returns 1 if a copy could not be made; the caller then changes nothing.
brain_preserve_ignored(){
  local list tree p hit dest="" n=0 s
  local -a junk=()
  while IFS= read -r s; do junk+=("${s/:(/:(exclude,}"); done < <(team_os_junk_pathspecs)
  list=$(mktemp "${TMPDIR:-/tmp}/brain-list.XXXXXX") || { _brain_preserve_fail "no temporary file"; return 1; }
  tree=$(mktemp "${TMPDIR:-/tmp}/brain-tree.XXXXXX") || { rm -f "$list"; _brain_preserve_fail "no temporary file"; return 1; }
  git -C "$MIRROR" ls-files -o -i --exclude-standard -z -- . "${junk[@]}" > "$list" 2>/dev/null \
    && git -C "$MIRROR" ls-tree -r -z origin/main 2>/dev/null | tr '\0' '\n' > "$tree" \
    || { rm -f "$list" "$tree"; _brain_preserve_fail "could not list ignored files"; return 1; }
  # An ignored file is lost when the incoming tree has a file at its path, spelled in any capitals (this
  # Mac's volume folds them), or at one of its parent folders. Same text at the same path: nothing to lose.
  # ponytail: paths with a newline in the incoming tree are not matched; ASCII-only case folding.
  while IFS= read -r -d '' p; do
    hit=$(awk -F'\t' -v p="$p" 'BEGIN{lp=tolower(p)} {split($1,a," "); if(a[2]!="blob")next; q=tolower($2)
      if(q==lp){print "E " a[3]; exit} if(index(lp,q "/")==1){print "P"; exit}}' "$tree")
    [ -n "$hit" ] || continue
    [ "${hit#E }" = "$hit" ] || [ -L "$MIRROR/$p" ] || [ "$(git -C "$MIRROR" hash-object -- "$p" 2>/dev/null)" != "${hit#E }" ] || continue
    _brain_keep_one "$BRAIN_REPLACED" dest "" "$p" || { rm -f "$list" "$tree"; _brain_preserve_fail "an ignored file"; return 1; }
    n=$((n+1))
  done < "$list"
  rm -f "$list" "$tree"
  [ "$n" -eq 0 ] || log "$n ignored local file(s) are about to be replaced by a colleague's; kept in $dest"
}

# Returns 1 if ANY copy could not be made; the caller then resets nothing.
brain_preserve_unsent(){
  local list base udest="" pdest="" p n=0 np=0 have_head=0
  git -C "$MIRROR" rev-parse -q --verify HEAD >/dev/null 2>&1 && have_head=1
  list=$(mktemp "${TMPDIR:-/tmp}/brain-list.XXXXXX") || { _brain_preserve_fail "no temporary file"; return 1; }
  base=$(git -C "$MIRROR" merge-base origin/main HEAD 2>/dev/null) || base=HEAD
  {
    if [ "$have_head" -eq 1 ]; then
      git -C "$MIRROR" log -z --format= --name-only --no-renames origin/main..HEAD -- &&
      git -C "$MIRROR" diff --name-only -z --no-renames HEAD --
    fi &&
    git -C "$MIRROR" ls-files -o --exclude-standard -z
  } > "$list" 2>/dev/null || { rm -f "$list"; _brain_preserve_fail "could not list what changed"; return 1; }
  while IFS= read -r -d '' p; do
    [ -n "$p" ] && [ "$p" != "$BRAIN_SIGNPOST" ] || continue
    [ -e "$MIRROR/$p" ] || [ -L "$MIRROR/$p" ] || continue
    if brain_path_protected "$p"; then
      [ -e "$pdest/$p" ] || [ -L "$pdest/$p" ] || {
        _brain_keep_one "$BRAIN_PROTECTED_EDITS" pdest "" "$p" || { rm -f "$list"; _brain_preserve_fail "a locked page"; return 1; }
        np=$((np+1)); }
    else
      [ -e "$udest/files/$p" ] || [ -L "$udest/files/$p" ] || {
        _brain_keep_one "$BRAIN_UNSENT" udest files/ "$p" || { rm -f "$list"; _brain_preserve_fail "an unsent page"; return 1; }
        n=$((n+1)); }
    fi
  done < "$list"
  rm -f "$list"
  brain_preserve_ignored || return 1
  if [ "$n" -gt 0 ]; then
    local -a ex=()
    while IFS= read -r p; do ex+=("$p"); done < <(brain_protected_excludes)
    git -C "$MIRROR" diff --binary "$base" -- . "${ex[@]}" > "$udest/changes.patch" 2>/dev/null \
      || { _brain_preserve_fail "the patch of unsent work"; return 1; }
    log "this Mac can no longer write to the Brain; $n unsent file(s) kept in $udest"
  fi
  [ "$np" -eq 0 ] || log "locked Brain page(s) changed on a read-only Mac, not shared: $np kept in $pdest"
  rm -f "$BRAIN_PRESERVE_FAILED"
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
  # Parked only once the refusal is dealt with (or cannot be). A copy that fails below parks nothing:
  # the next cycle pushes, is refused again and retries the copy, instead of leaving the person's
  # ordinary notes unsent behind a "nothing has changed" verdict.
  local -a prot=()
  while IFS= read -r -d '' p; do brain_path_protected "$p" && prot+=("$p"); done < <(git diff --name-only -z --no-renames origin/main HEAD --)
  [ "${#prot[@]}" -gt 0 ] || { echo "$origin_sha $local_sha" > "$BRAIN_PUSH_PARKED"; log "GitHub refused the Brain push but none of our changes touch a protected path; parked"; return 1; }
  dest=$(_brain_keep_dir "$BRAIN_PROTECTED_EDITS") || return 1
  for p in "${prot[@]}"; do
    if git cat-file -e "HEAD:$p" 2>/dev/null; then
      mkdir -p "$dest/$(dirname "$p")" && git show "HEAD:$p" > "$dest/$p" || { _brain_preserve_fail "a refused locked page"; return 1; }
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
  brain_preserve_ignored || return 1   # before anything below can replace a file
  git -C "$MIRROR" config core.hooksPath "$MIRROR/.git/hooks"
  install_team_hooks "$MIRROR" "$STATE/engine/lib" || log "could not install the secret-scan hooks in the Brain"
  # Label "mirror", not "brain": brain-app's SyncStatus reads "mirror at <sha>" as the mirror step,
  # and an unknown line leaves every writable Mac yellow (2026-10-09). Keep in step with brain-app.
  _sync_after_fetch "$MIRROR" mirror "$BRAIN_CONFLICT_STATE" "$BRAIN_CONFLICT_PARK_SHAS" "$BRAIN_AUTOSTASH_STATE" brain_push_hook || rc=$?
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
  if [ -f "$BRAIN_PRESERVE_FAILED" ]; then
    printf 'Some changes in the Serlinolab_Brain folder could not be saved to a safe place on this Mac.\nNothing in the Serlinolab_Brain folder was changed - your files are exactly as you left them.\nPlease tell Max.\n' > "$MARK"; return 0
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
  d=$(find "$BRAIN_REPLACED" -mindepth 1 -maxdepth 1 -type d -mmin "-$BRAIN_NOTICE_MINUTES" 2>/dev/null | sort | tail -1)
  if [ -n "$d" ]; then
    printf 'A file of yours in the Serlinolab_Brain folder was replaced by a colleague'"'"'s file of the same name.\nYour version is kept here:\n  %s\n' "$d" > "$MARK"; return 0
  fi
  # Last on purpose: a size notice must never hide text that was kept or not shared above.
  if [ -s "$STATE/brain_oversized_rejects" ]; then
    printf 'A file in the Serlinolab_Brain folder is too big to share and was left out:\n  %s\n' "$(head -1 "$STATE/brain_oversized_rejects")" > "$MARK"; return 0
  fi
  return 1
}
