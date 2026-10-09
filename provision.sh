#!/bin/bash
# Run by Max on his own Mac, once per new person/Mac, after they paste back the
# SERLINO-BRAIN-SETUP line setup.sh printed. Uses the gh CLI only - no SSH key of
# Max's own is needed, since deploy keys are registered through the GitHub API.
#
#   ./provision.sh [--dry-run] "SERLINO-BRAIN-SETUP person=alice machine=alices-mac mirror_key=ssh-ed25519 AAAA... brain-mirror-alices-mac team_key=ssh-ed25519 AAAA... brain-team-alice"
#
# MAX-1790: the Brain key is registered WITH write access (the Mac edits the Brain directly; the
# GitHub push ruleset keeps protected paths out). A Mac provisioned earlier holds a read-only key:
# re-running this with its pasted line upgrades it, or, with nothing from that Mac, by title:
#
#   ./provision.sh [--dry-run] --upgrade-brain-key "brain-mirror alice alices-mac"
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="${GH:-gh}"
BRAIN_ORG="${BRAIN_ORG:-serlinolab}"
MIRROR_REPO="Serlinolab-Brain"
TEAM_REPO="brain-team"
TEAM_README_TEMPLATE="$SCRIPT_DIR/templates/team-repo-README.md"

DRY_RUN=0
LINE=""
UPGRADE_TITLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --upgrade-brain-key) shift; UPGRADE_TITLE="${1:-}" ;;
    *) LINE="$1" ;;
  esac
  shift
done
if [ -z "$LINE" ] && [ -z "$UPGRADE_TITLE" ]; then
  echo "Usage: provision.sh [--dry-run] '<pasted SERLINO-BRAIN-SETUP line>' | --upgrade-brain-key '<existing key title>'" >&2
  exit 1
fi

refuse(){ echo "Refusing: $*" >&2; exit 1; }

# MAX-1790: GitHub cannot flip read_only on an existing deploy key, so the upgrade deletes the
# read-only key and registers the SAME public key again under the SAME title with write access.
# The only read_only change this script ever makes, and only for the Brain repo.
#
# The delete is the dangerous half: a failure after it leaves the Mac with NO key. So (1) the org,
# repo, title and PUBLIC key are saved to $RECOVERY_DIR before anything is deleted (a public key is
# not a secret), and the upgrade refuses if that cannot be written; (2) the write registration is
# retried once; (3) if it still fails, the old read-only key is registered again so the Mac keeps
# working; (4) if even that fails, the exact way back is printed. Re-running
# `--upgrade-brain-key <title>` reads the saved material, so the title alone is enough to finish.
# A DELETE that answers with an error may still have been applied, so the saved file is never
# dropped on that answer: the key list says what happened. The file is used only for the org, repo
# and title it was written for, and is dropped as soon as a writable key under that title exists
# on GitHub by any path (recovery_forget, below) - a key revoked later must not come back from it.
RECOVERY_DIR="${BRAIN_PROVISION_STATE:-$HOME/.serlino-brain-provision}"
recovery_file(){ printf '%s/upgrade-%s.tsv' "$RECOVERY_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; }
recovery_forget(){ [ "$DRY_RUN" -eq 1 ] || rm -f "$(recovery_file "$1")"; }

# Registers $2 (title) / $3 (key) writable on the Brain repo; one retry. Returns 0 on success.
register_brain_key_writable(){
  register_key_mutate "$MIRROR_REPO" "$1" "$2" false && return 0
  echo "registering with write access failed; trying once more" >&2
  register_key_mutate "$MIRROR_REPO" "$1" "$2" false
}

# The key is gone from GitHub and is being brought back (after the delete, or from saved material).
# $1 title, $2 public key, $3 recovery file. Success removes the file.
brain_key_reregister(){
  if register_brain_key_writable "$1" "$2"; then rm -f "$3"; return 0; fi
  echo "write registration failed twice; registering the old read-only key again so this Mac keeps working" >&2
  if register_key_mutate "$MIRROR_REPO" "$1" "$2" true; then
    echo "The Mac's read-only key was put back; it still reads the Brain but cannot write yet." >&2
    echo "Run this again later to finish the upgrade (the saved key is in $3):" >&2
    echo "  ./provision.sh --upgrade-brain-key '$1'" >&2
    return 1
  fi
  echo "ERROR: '$1' has NO key on $MIRROR_REPO now - this Mac cannot read the Brain until it is registered." >&2
  echo "Run this again when GitHub answers (the saved key is in $3):" >&2
  echo "  ./provision.sh --upgrade-brain-key '$1'" >&2
  echo "Or register it by hand (public key, safe to paste):" >&2
  echo "  gh api repos/$BRAIN_ORG/$MIRROR_REPO/keys -f title='$1' -f key='$2' -F read_only=false" >&2
  return 1
}

# $1 key id, $2 title, $3 public key. A DELETE error is ambiguous (the server may have deleted the key
# and lost the answer), so the key list decides: the key (its public key, not its title) still there ->
# nothing was deleted, report and keep the saved key; gone -> carry on to the registration. A list that fails is
# unknown, never "gone": the saved key stays and the printed way back works either way.
upgrade_key_mutate(){
  local rf rows t k ro id gone=1 want; rf=$(recovery_file "$2")
  want=$(awk '{print $1, $2}' <<<"$3")
  mkdir -p "$RECOVERY_DIR" && printf '%s\t%s\t%s\t%s\n' "$BRAIN_ORG" "$MIRROR_REPO" "$2" "$3" > "$rf" \
    || { echo "refusing: could not save the recovery material in $RECOVERY_DIR; nothing was deleted" >&2; return 1; }
  echo "deleting read-only deploy key $1 ('$2') on $MIRROR_REPO, registering the same key again with write access (key saved in $rf first)"
  if ! "$GH" api -X DELETE "repos/$BRAIN_ORG/$MIRROR_REPO/keys/$1" >/dev/null; then
    echo "the delete answered with an error; asking GitHub whether it was applied anyway" >&2
    if ! rows=$(gh_keys_rows "$MIRROR_REPO"); then
      echo "could not tell. The saved key is kept in $rf; run './provision.sh --upgrade-brain-key '$2'' to finish or check." >&2
      return 1
    fi
    while IFS=$'\t' read -r t k ro id; do
      [ "$(awk '{print $1, $2}' <<<"$k")" = "$want" ] && gone=0   # the key itself, never the title (a twin may share it)
    done <<<"$rows"
    if [ "$gone" -eq 0 ]; then
      echo "the key is still registered; nothing was deleted. The saved key is kept in $rf." >&2
      return 1
    fi
  fi
  brain_key_reregister "$2" "$3" "$rf"
}
# $1 repo rows, $2 title: refuses (returns 1) when more than one key carries the title - which of them is
# "ours" is then a guess, and a delete or an upgrade must never be a guess.
title_unambiguous(){
  [ "$(awk -F'\t' -v t="$2" '$1==t' <<<"$1" | wc -l)" -le 1 ] && return 0
  echo "refusing: more than one deploy key on $MIRROR_REPO is titled '$2'; remove the extra ones on GitHub first, nothing was changed" >&2
  return 1
}
upgrade_brain_key(){
  local rows t k ro id rf so sr st saved_key
  rows=$(gh_keys_rows "$MIRROR_REPO") || return 1
  title_unambiguous "$rows" "$1" || return 1
  while IFS=$'\t' read -r t k ro id; do
    [ "$t" = "$1" ] || continue
    if [ "$ro" != true ]; then echo "already writable: '$1' on $MIRROR_REPO"; recovery_forget "$1"; return 0; fi
    [ -n "$id" ] || { echo "refusing: no id for '$1' on $MIRROR_REPO" >&2; return 1; }
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "would delete deploy key $id ('$1') on $MIRROR_REPO and register the same key again, read_only=false"
      return 0
    fi
    upgrade_key_mutate "$id" "$1" "$k"
    return
  done <<<"$rows"
  # Not on GitHub. An earlier upgrade that failed after its delete left the key in the saved material.
  rf=$(recovery_file "$1")
  if [ -s "$rf" ]; then
    IFS=$'\t' read -r so sr st saved_key < "$rf"
    if [ "$so" = "$BRAIN_ORG" ] && [ "$sr" = "$MIRROR_REPO" ] && [ "$st" = "$1" ] && [[ "$saved_key" == ssh-ed25519\ * ]]; then
      if [ "$DRY_RUN" -eq 1 ]; then echo "would register the saved key for '$1' on $MIRROR_REPO with write access (from $rf)"; return 0; fi
      echo "'$1' has no key on $MIRROR_REPO; finishing the interrupted upgrade from $rf"
      brain_key_reregister "$1" "$saved_key" "$rf"
      return
    fi
  fi
  echo "refusing: no deploy key titled '$1' on $MIRROR_REPO" >&2
  return 1
}

if [ -z "$UPGRADE_TITLE" ]; then
person=$(printf '%s' "$LINE" | sed -nE 's/.*person=([^ ]*) machine=.*/\1/p')
machine=$(printf '%s' "$LINE" | sed -nE 's/.*machine=([^ ]*) mirror_key=.*/\1/p')
mirror_key=$(printf '%s' "$LINE" | sed -nE 's/.*mirror_key=(.*) team_key=.*/\1/p')
team_key=$(printf '%s' "$LINE" | sed -nE 's/.*team_key=(.*)$/\1/p')

[[ "$person" =~ ^[a-z0-9-]+$ ]] || refuse "not a valid person slug: '$person'"
[[ "$machine" =~ ^[a-zA-Z0-9._-]+$ ]] || refuse "not a valid machine name: '$machine'"
[[ "$mirror_key" == ssh-ed25519\ * ]] || refuse "mirror_key does not look like an ssh-ed25519 public key"
[[ "$team_key" == ssh-ed25519\ * ]] || refuse "team_key does not look like an ssh-ed25519 public key"
fi

# AC-1: re-running is safe. Same title + same key -> success, nothing changes. Same title
# with a different key, a different read_only flag under the same title/key, or the same key
# already under a different title -> refuse and change nothing. A key is never deleted or
# overwritten by this script.
#
# Class C review fixes, all in the one lookup this function makes:
#  1. read_only is verified, not just presence: a mismatch (mirror key not read-only, or team
#     key wrongly read-only) is refused rather than silently accepted.
#  2. A failed lookup (gh exits non-zero) is NOT treated as "no such key" - it is refused, so
#     a transient API failure can never lead to a duplicate registration.
#  3. `--paginate` - GitHub caps a single page at 30 keys; without it, a key past the first
#     page would look absent and get re-registered.
#  4. Only the key MATERIAL (type + base64 blob, the first two whitespace-separated fields)
#     is compared - not the trailing comment, which GitHub does not treat as part of the key
#     and which our own re-runs regenerate per machine/person anyway.
#
# MAX-1515 fix 1: read-only. Never mutates. Sets $NEED_REGISTER to 0 (already registered
# correctly - phase 2 has nothing to do) or 1 (phase 2 must register it). The GET this makes is
# the ONLY deploy-keys lookup for this repo across the whole run - phase 2 must not repeat it.
#
# MAX-1790: $5 = 1 allows ONE change of read_only - an existing read-only key on this repo,
# same title and same key, wanted writable - and reports it as NEED_REGISTER=2 with the key's id
# in $UPGRADE_KEY_ID. Every other mismatch still refuses, on both repos.
gh_keys_rows(){
  "$GH" api --paginate "repos/$BRAIN_ORG/$1/keys" --jq '.[] | [.title,.key,.read_only,.id] | @tsv' 2>/dev/null && return 0
  echo "refusing: could not look up existing deploy keys on $1 (the gh lookup failed - treated as unknown, never as absent)" >&2
  return 1
}

register_key_check(){
  local repo="$1" title="$2" key="$3" want_ro="$4" allow_upgrade="${5:-0}"
  local key_material; key_material=$(awk '{print $1, $2}' <<<"$key")
  NEED_REGISTER=1

  local rows
  rows=$(gh_keys_rows "$repo") || return 1
  [ "$repo" != "$MIRROR_REPO" ] || title_unambiguous "$rows" "$title" || return 1

  local t k ro id material
  while IFS=$'\t' read -r t k ro id; do
    [ -n "$t" ] || continue
    material=$(awk '{print $1, $2}' <<<"$k")
    if [ "$t" = "$title" ]; then
      [ "$repo" = "$MIRROR_REPO" ] && recovery_forget "$title"   # a key under this title exists: a saved one is stale
      if [ "$material" != "$key_material" ]; then
        echo "refusing: a deploy key titled '$title' already exists on $repo with a different key" >&2
        return 1
      fi
      if [ "$allow_upgrade" = 1 ] && [ "$ro" = true ] && [ "$want_ro" = false ]; then
        [ -n "$id" ] || { echo "refusing: no id for '$title' on $repo, cannot upgrade it" >&2; return 1; }
        echo "will upgrade deploy key '$title' on $repo from read-only to read_only=false (delete it, register the same key again)"
        NEED_REGISTER=2; UPGRADE_KEY_ID="$id"
        return 0
      fi
      if [ "$ro" != "$want_ro" ]; then
        echo "refusing: '$title' on $repo is registered with read_only=$ro, expected read_only=$want_ro - refusing to change it" >&2
        return 1
      fi
      echo "already registered: '$title' on $repo"
      NEED_REGISTER=0
      return 0
    fi
    if [ "$material" = "$key_material" ]; then
      echo "refusing: this key is already registered on $repo, under a different title ('$t')" >&2
      return 1
    fi
  done <<<"$rows"

  echo "will register deploy key '$title' on $repo (read_only=$want_ro)"
  return 0
}

# Mutation only, no GET - assumes register_key_check already decided this is needed.
register_key_mutate(){
  local repo="$1" title="$2" key="$3" want_ro="$4"
  echo "registering deploy key '$title' on $repo (read_only=$want_ro)"
  "$GH" api "repos/$BRAIN_ORG/$repo/keys" -f title="$title" -f key="$key" -F "read_only=$want_ro" >/dev/null || return 1
  # a writable Brain key now exists under this title, by whatever path: a saved one can only be stale
  [ "$repo" = "$MIRROR_REPO" ] && [ "$want_ro" = false ] && recovery_forget "$title"
  return 0
}

# AC-1a: only a DEFINITE 404 means "absent" - any other lookup failure (network, 5xx, auth)
# is refused rather than treated as "safe to create". `gh` reports every HTTP error on
# stderr with the status code in it ("... (HTTP <code>)"), so that's the one signal trusted
# to distinguish "doesn't exist" from "couldn't find out". $2 (optional) is a --jq expression;
# its output is echoed on success. Exit code: 0 exists (stdout carries --jq's output), 1
# confirmed absent (404), 2 unknown/error (stderr carries gh's message).
gh_lookup(){
  local path="$1" jq_expr="${2:-}" out err rc errfile
  errfile=$(mktemp) || return 2
  if [ -n "$jq_expr" ]; then
    out=$("$GH" api "$path" --jq "$jq_expr" 2>"$errfile")
  else
    out=$("$GH" api "$path" 2>"$errfile")
  fi
  rc=$?
  err=$(cat "$errfile" 2>/dev/null); rm -f "$errfile"
  if [ "$rc" -eq 0 ]; then printf '%s' "$out"; return 0; fi
  case "$err" in
    *'HTTP 404'*) return 1 ;;
    *) [ -n "$err" ] && echo "$err" >&2; return 2 ;;
  esac
}

# AC-1 Class C review fix 5: verifies a repo's identity (the exact org/name - never a rename
# or redirect that `gh` silently followed) and privacy, for BOTH repositories this script
# touches, before any key is registered or anything is created against either one. One lookup
# covers both checks.
# Return: 0 exists, full_name matches exactly, and private=true.
#         1 confirmed absent (404) - only the team repo may be created by this script; the
#           mirror repo never is, so a caller checking it must treat this like case 2.
#         2 refused: not private, resolved to a different full_name, or the lookup itself
#           failed (unknown, never treated as safe) - a message is already on stderr.
verify_repo_identity(){
  local repo="$1" row rc private full_name
  row=$(gh_lookup "repos/$BRAIN_ORG/$repo" '[.private,.full_name] | @tsv'); rc=$?
  case "$rc" in
    0) : ;;
    1) return 1 ;;
    *)
      echo "refusing: could not look up repo $BRAIN_ORG/$repo (the gh lookup failed - treated as unknown, never as absent)" >&2
      return 2
      ;;
  esac
  IFS=$'\t' read -r private full_name <<<"$row"
  if [ "$full_name" != "$BRAIN_ORG/$repo" ]; then
    echo "refusing: repo $BRAIN_ORG/$repo resolved to '$full_name' instead of '$BRAIN_ORG/$repo' - refusing to register a key against a renamed or redirected repo" >&2
    return 2
  fi
  if [ "$private" != true ]; then
    echo "refusing: repo $BRAIN_ORG/$repo already exists and is not private - refusing to touch it" >&2
    return 2
  fi
  return 0
}

# AC-1: the team repo is created once, private, with an initial commit on main (so
# origin/main exists for the first clone) containing a README that says in plain words the
# folder is shared with the team.
#
# Should-fix from the review: if a previous run created the repo but was interrupted before
# the initial commit landed, the repo exists but has no main branch - re-running used to
# report success on that empty repo forever. Presence of README.md on main is now checked
# separately from repo existence, and the initial commit is retried whenever it's missing.
#
# MAX-1515 fix 1: read-only. Never mutates. Sets $NEED_CREATE_REPO and $NEED_README so phase 2
# knows exactly what to do without looking anything up itself. A repo that does not exist yet
# always needs both; an existing repo's README is checked on its own (this is also what makes
# --dry-run notice a 5xx here, since this now runs in phase 1, before it).
team_repo_check(){
  NEED_CREATE_REPO=0
  NEED_README=0
  local rc
  verify_repo_identity "$TEAM_REPO"; rc=$?
  case "$rc" in
    0) : ;;   # exists - the README check below decides NEED_README
    1) NEED_CREATE_REPO=1; NEED_README=1; return 0 ;;   # confirmed absent - phase 2 creates + seeds it
    *) return 1 ;;   # verify_repo_identity already printed the refusal
  esac

  gh_lookup "repos/$BRAIN_ORG/$TEAM_REPO/contents/README.md" >/dev/null; rc=$?
  case "$rc" in
    0) return 0 ;;   # has its initial commit already
    1) NEED_README=1; return 0 ;;   # confirmed absent - phase 2 retries the initial commit
    *)
      echo "refusing: could not look up README.md on $BRAIN_ORG/$TEAM_REPO (the gh lookup failed - treated as unknown, never as absent)" >&2
      return 1
      ;;
  esac
}

# Mutations only - no GETs, no decisions, everything it needs was decided in team_repo_check.
team_repo_mutate(){
  if [ "$NEED_CREATE_REPO" -eq 1 ]; then
    echo "creating private repo $BRAIN_ORG/$TEAM_REPO"
    "$GH" repo create "$BRAIN_ORG/$TEAM_REPO" --private --description "Serlino Brain - team folder" || return 1
  fi
  if [ "$NEED_README" -eq 1 ]; then
    echo "repo $BRAIN_ORG/$TEAM_REPO has no initial commit yet - creating it"
    "$GH" api -X PUT "repos/$BRAIN_ORG/$TEAM_REPO/contents/README.md" \
      -f message="Initial commit" -f content="$README_CONTENT" -f branch=main >/dev/null || return 1
  fi
}

# MAX-1515 fixes 1/2/3: phase 1 is every read-only check this run will need - repo identity and
# privacy for BOTH repositories, the team repo's README-exists state, and the key-registration
# decision for BOTH keys - and it structurally never mutates anything (team_repo_check and
# register_key_check never call a mutating gh command). It records every decision into
# NEED_CREATE_REPO / NEED_README / NEED_MIRROR_KEY / NEED_TEAM_KEY, so phase 2 (below) can
# perform exactly those mutations without looking any of it up again - not even a second
# deploy-keys GET to double-check what phase 1 already established (fix 1: that repeat GET
# used to mean a transient failure there could leave phase 2's earlier mutations - the README
# commit, the mirror key - stuck registered while the run still reported failure).
#
# A team repo that does not exist yet is not a failure here: there is no keys endpoint to look
# up on a repo that does not exist, so its key always needs registering and no lookup is
# attempted (fix 2 - a first-ever provisioning used to look up keys on the not-yet-created team
# repo and refuse every time).
phase1_checks(){
  # Encoded here, not in phase 2: a missing or unreadable template must refuse before anything is created.
  # No pipe: base64's own exit status must count, not tr's - partial output from a failed encode is refused.
  if ! README_CONTENT=$(base64 < "$TEAM_README_TEMPLATE" 2>/dev/null) || [ -z "$README_CONTENT" ]; then
    echo "refusing: team README template missing or unreadable at $TEAM_README_TEMPLATE" >&2; return 1
  fi
  README_CONTENT=${README_CONTENT//$'\n'/}
  team_repo_check || return 1

  verify_repo_identity "$MIRROR_REPO"; local mirror_rc=$?
  case "$mirror_rc" in
    0) : ;;
    1)
      echo "refusing: repo $BRAIN_ORG/$MIRROR_REPO does not exist - it must already exist before keys can be registered against it (this script never creates it)" >&2
      return 1
      ;;
    *) return 1 ;;   # verify_repo_identity already printed the refusal
  esac

  register_key_check "$MIRROR_REPO" "brain-mirror $person $machine" "$mirror_key" false 1 || return 1
  NEED_MIRROR_KEY="$NEED_REGISTER"

  if [ "$NEED_CREATE_REPO" -eq 1 ]; then
    NEED_TEAM_KEY=1
  else
    register_key_check "$TEAM_REPO" "brain-team $person $machine" "$team_key" false || return 1
    NEED_TEAM_KEY="$NEED_REGISTER"
  fi
}

# Mutations only, and only ever called once phase1_checks has passed in full. Issues no GETs.
# ponytail: a concurrent external change to either repo between phase 1 and phase 2 is not
# guarded here - single operator, seconds apart, running this by hand once per new person/Mac.
phase2_mutate(){
  team_repo_mutate || return 1
  # An upgrade deletes first (GitHub refuses the same key twice); upgrade_key_mutate saves the key,
  # retries, and falls back to the read-only key, so a failure after the delete is recoverable.
  [ "$NEED_MIRROR_KEY" -eq 2 ] && { upgrade_key_mutate "$UPGRADE_KEY_ID" "brain-mirror $person $machine" "$mirror_key" || return 1; }
  [ "$NEED_MIRROR_KEY" -eq 1 ] && { register_key_mutate "$MIRROR_REPO" "brain-mirror $person $machine" "$mirror_key" false || return 1; }
  [ "$NEED_TEAM_KEY" -eq 1 ] && { register_key_mutate "$TEAM_REPO" "brain-team $person $machine" "$team_key" false || return 1; }
  return 0
}

NEED_CREATE_REPO=0; NEED_README=0; NEED_MIRROR_KEY=0; NEED_TEAM_KEY=0; README_CONTENT=""; UPGRADE_KEY_ID=""

if [ -n "$UPGRADE_TITLE" ]; then
  verify_repo_identity "$MIRROR_REPO" || exit 1
  upgrade_brain_key "$UPGRADE_TITLE" || exit 1
  exit 0
fi

phase1_checks || exit 1
[ "$DRY_RUN" -eq 1 ] && exit 0

phase2_mutate || exit 1
echo "Provisioning complete for $person@$machine."
