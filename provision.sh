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
# with a different key, or the same key already under a different title -> refuse and change
# nothing. A key is never deleted or overwritten by this script.
register_key(){
  local repo="$1" title="$2" key="$3" readonly="$4"
  local existing_key dup_title
  existing_key=$("$GH" api "repos/$BRAIN_ORG/$repo/keys" --jq ".[] | select(.title==\"$title\") | .key" 2>/dev/null)
  if [ -n "$existing_key" ]; then
    if [ "$existing_key" = "$key" ]; then
      echo "already registered: '$title' on $repo"
      return 0
    fi
    echo "refusing: a deploy key titled '$title' already exists on $repo with a different key" >&2
    return 1
  fi
  dup_title=$("$GH" api "repos/$BRAIN_ORG/$repo/keys" --jq ".[] | select(.key==\"$key\") | .title" 2>/dev/null)
  if [ -n "$dup_title" ]; then
    echo "refusing: this key is already registered on $repo, under a different title ('$dup_title')" >&2
    return 1
  fi
  echo "registering deploy key '$title' on $repo (read_only=$readonly)"
  [ "$DRY_RUN" -eq 1 ] && return 0
  "$GH" api "repos/$BRAIN_ORG/$repo/keys" -f title="$title" -f key="$key" -F "read_only=$readonly" >/dev/null
}

# AC-1: the team repo is created once, private, with an initial commit on main (so
# origin/main exists for the first clone) containing a README that says in plain words the
# folder is shared with the team.
ensure_team_repo(){
  if "$GH" api "repos/$BRAIN_ORG/$TEAM_REPO" >/dev/null 2>&1; then
    echo "repo $BRAIN_ORG/$TEAM_REPO already exists"
    return 0
  fi
  echo "creating private repo $BRAIN_ORG/$TEAM_REPO"
  [ "$DRY_RUN" -eq 1 ] && return 0
  "$GH" repo create "$BRAIN_ORG/$TEAM_REPO" --private --description "Serlino Brain - team folder" || return 1
  local content
  content=$(base64 < "$TEAM_README_TEMPLATE" | tr -d '\n')
  "$GH" api -X PUT "repos/$BRAIN_ORG/$TEAM_REPO/contents/README.md" \
    -f message="Initial commit" -f content="$content" -f branch=main >/dev/null
}

ensure_team_repo || exit 1
register_key "$MIRROR_REPO" "brain-mirror $person $machine" "$mirror_key" true || exit 1
register_key "$TEAM_REPO" "brain-team $person $machine" "$team_key" false || exit 1
echo "Provisioning complete for $person@$machine."
