#!/bin/bash
# Run by Max on his own Mac, once per new person/Mac, after they paste back the
# SERLINO-BRAIN-SETUP line setup.sh printed. Uses the gh CLI only - no SSH key of
# Max's own is needed, since deploy keys are registered through the GitHub API.
#
#   ./provision.sh [--dry-run] "SERLINO-BRAIN-SETUP person=alice machine=alices-mac mirror_key=ssh-ed25519 AAAA... brain-mirror-alices-mac team_key=ssh-ed25519 AAAA... brain-team-alice"
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="${GH:-gh}"
BRAIN_ORG="${BRAIN_ORG:-serlinolab}"
MIRROR_REPO="Serlinolab-Brain"
TEAM_REPO="brain-team"
TEAM_README_TEMPLATE="$SCRIPT_DIR/templates/team-repo-README.md"

DRY_RUN=0
LINE=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) LINE="$arg" ;;
  esac
done
[ -n "$LINE" ] || { echo "Usage: provision.sh [--dry-run] '<pasted SERLINO-BRAIN-SETUP line>'" >&2; exit 1; }

refuse(){ echo "Refusing: $*" >&2; exit 1; }

person=$(printf '%s' "$LINE" | sed -nE 's/.*person=([^ ]*) machine=.*/\1/p')
machine=$(printf '%s' "$LINE" | sed -nE 's/.*machine=([^ ]*) mirror_key=.*/\1/p')
mirror_key=$(printf '%s' "$LINE" | sed -nE 's/.*mirror_key=(.*) team_key=.*/\1/p')
team_key=$(printf '%s' "$LINE" | sed -nE 's/.*team_key=(.*)$/\1/p')

[[ "$person" =~ ^[a-z0-9-]+$ ]] || refuse "not a valid person slug: '$person'"
[[ "$machine" =~ ^[a-zA-Z0-9._-]+$ ]] || refuse "not a valid machine name: '$machine'"
[[ "$mirror_key" == ssh-ed25519\ * ]] || refuse "mirror_key does not look like an ssh-ed25519 public key"
[[ "$team_key" == ssh-ed25519\ * ]] || refuse "team_key does not look like an ssh-ed25519 public key"

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
register_key_check(){
  local repo="$1" title="$2" key="$3" want_ro="$4"
  local key_material; key_material=$(awk '{print $1, $2}' <<<"$key")
  NEED_REGISTER=1

  local rows
  if ! rows=$("$GH" api --paginate "repos/$BRAIN_ORG/$repo/keys" --jq '.[] | [.title,.key,.read_only] | @tsv' 2>/dev/null); then
    echo "refusing: could not look up existing deploy keys on $repo (the gh lookup failed - treated as unknown, never as absent)" >&2
    return 1
  fi

  local t k ro material
  while IFS=$'\t' read -r t k ro; do
    [ -n "$t" ] || continue
    material=$(awk '{print $1, $2}' <<<"$k")
    if [ "$t" = "$title" ]; then
      if [ "$material" != "$key_material" ]; then
        echo "refusing: a deploy key titled '$title' already exists on $repo with a different key" >&2
        return 1
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
  "$GH" api "repos/$BRAIN_ORG/$repo/keys" -f title="$title" -f key="$key" -F "read_only=$want_ro" >/dev/null
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
    local content
    content=$(base64 < "$TEAM_README_TEMPLATE" | tr -d '\n') && [ -n "$content" ] || return 1
    "$GH" api -X PUT "repos/$BRAIN_ORG/$TEAM_REPO/contents/README.md" \
      -f message="Initial commit" -f content="$content" -f branch=main >/dev/null || return 1
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
  # A missing template would base64 to an empty README committed in phase 2, reported as success.
  [ -s "$TEAM_README_TEMPLATE" ] || { echo "refusing: team README template missing at $TEAM_README_TEMPLATE" >&2; return 1; }
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

  register_key_check "$MIRROR_REPO" "brain-mirror $person $machine" "$mirror_key" true || return 1
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
  [ "$NEED_MIRROR_KEY" -eq 1 ] && { register_key_mutate "$MIRROR_REPO" "brain-mirror $person $machine" "$mirror_key" true || return 1; }
  [ "$NEED_TEAM_KEY" -eq 1 ] && { register_key_mutate "$TEAM_REPO" "brain-team $person $machine" "$team_key" false || return 1; }
  return 0
}

NEED_CREATE_REPO=0; NEED_README=0; NEED_MIRROR_KEY=0; NEED_TEAM_KEY=0

phase1_checks || exit 1
[ "$DRY_RUN" -eq 1 ] && exit 0

phase2_mutate || exit 1
echo "Provisioning complete for $person@$machine."
