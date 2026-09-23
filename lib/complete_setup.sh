#!/bin/bash
# MAX-1515 change A: the idempotent clone/configure steps that finish a Mac's setup once Max
# has registered its deploy keys - the team clone (--no-checkout -> configure -> checkout) and
# the read-only mirror clone. Moved out of setup.sh (unchanged in substance) so both setup.sh's
# own run AND every sync cycle (lib/sync.sh) can call the same code - a creator never pastes
# the setup line a second time; whichever runs next picks up exactly where the last attempt
# left off.
#
# Reuses only what setup.sh already saved on disk: the SSH keys and Host aliases it wrote, and
# $ROOT/.state itself. Never reads or writes personal/. Never installs the launchd job - that
# stays setup.sh's own job, run whether or not this succeeds.
#
# Self-locates its sibling libraries so it works whether sourced from $ENGINE/lib (setup.sh, a
# freshly cloned copy of this repo) or from a sync cycle's own $DIR/lib (sync.sh already runs
# from inside the engine clone) - the same trick sync.sh uses on itself.
_COMPLETE_SETUP_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/team_layout.sh
source "$_COMPLETE_SETUP_LIBDIR/team_layout.sh"
# shellcheck source=lib/secretscan.sh
source "$_COMPLETE_SETUP_LIBDIR/secretscan.sh"

EXPECTED_TEAM_REMOTE="${EXPECTED_TEAM_REMOTE:-git@brain-team:serlinolab/brain-team.git}"
EXPECTED_MIRROR_REMOTE="${EXPECTED_MIRROR_REMOTE:-git@brain-mirror:serlinolab/Serlinolab-Brain.git}"

# Moved verbatim from setup.sh's own local copy.
remote_matches() {
  local path="$1" expected="$2" url
  [ -d "$path/.git" ] || return 1
  [ "$(git -C "$path" remote get-url origin 2>/dev/null || true)" = "$expected" ] || return 1
  while IFS= read -r url; do
    [ "$url" = "$expected" ] || return 1
  done < <(git -C "$path" remote get-url --push --all origin 2>/dev/null)
}

# Finishes team/ and serlinolab/ against $ROOT/.state (STATE) - both must already be set by the
# caller (setup.sh sets them directly; lib/common.sh sets them for the sync engine).
#
# Returns: 0 fully complete (freshly finished this call, or already was - a no-op that changes
#            nothing on disk and clones nothing);
#          1 pending (a clone could not connect yet, e.g. the deploy key is not registered -
#            retry silently on the next call, nothing else in the caller should be blocked);
#          2 refused (an existing team/ or serlinolab/ has a foreign origin - never adopted,
#            never cloned over; the caller's own attention-marker logic already surfaces this);
#          3 the team clone itself succeeded but configuring it failed - the half-configured
#            clone is removed, never left half-configured on disk.
complete_setup() {
  local team="$ROOT/team" mirror="$ROOT/serlinolab"
  local team_ready=0 team_needs_checkout=0

  if [ -f "$STATE/team-configured" ]; then
    team_ready=1
  elif [ -e "$team" ]; then
    local actual
    actual=$(git -C "$team" remote get-url origin 2>/dev/null || echo '<missing origin>')
    if remote_matches "$team" "$EXPECTED_TEAM_REMOTE"; then
      team_ready=1
    else
      echo "Refusing to adopt $team: origin is $actual, expected $EXPECTED_TEAM_REMOTE (including push URLs)." >&2
      return 2
    fi
  else
    # --no-checkout: nothing is written to the working tree by the clone itself. core.hooksPath
    # and core.symlinks are pinned at clone time (-c, in force before anything else runs) and
    # persisted below, so a permissive global hooksPath or a colleague's symlink never has a
    # window to matter. HEAD is checked out explicitly, last, only once every configuration
    # step below has succeeded - so a pre-existing committed CLAUDE.md/.claude never has a
    # window to land on disk either.
    if git clone --quiet --no-checkout -c core.hooksPath="$team/.git/hooks" -c core.symlinks=false \
         "$EXPECTED_TEAM_REMOTE" "$team"; then
      team_ready=1
      team_needs_checkout=1
    else
      rm -rf "$team"
      echo "Team folder clone pending - it will complete once Max has registered your key." >&2
      return 1
    fi
  fi

  if [ "$team_ready" -eq 1 ] && [ ! -f "$STATE/team-configured" ]; then
    local configure_ok=1
    # core.hooksPath: a creator's global git config could set a relative core.hooksPath (e.g.
    # .githooks), which - unpinned - would make git skip .git/hooks entirely and run whatever a
    # colleague committed into team/.githooks/ instead. The repo-local value always wins.
    git -C "$team" config core.hooksPath "$team/.git/hooks" || configure_ok=0
    # core.symlinks=false: a colleague can commit symlinks that point outside team/. Checked
    # out as small plain files holding the target text instead of real symlinks.
    git -C "$team" config core.symlinks false || configure_ok=0
    write_team_sparse_checkout "$team" || configure_ok=0
    install_team_hooks "$team" "$STATE/engine/lib" || configure_ok=0
    if [ "$configure_ok" -eq 1 ] && [ "$team_needs_checkout" -eq 1 ]; then
      git -C "$team" checkout --quiet main || configure_ok=0
    fi
    if [ "$configure_ok" -eq 1 ]; then
      date -u +%FT%TZ > "$STATE/team-configured"
    else
      # A configuration step failed: never leave a half-configured team/ - or an unchecked-out
      # one - sitting on disk.
      [ "$team_needs_checkout" -eq 1 ] && rm -rf "$team"
      echo "Team folder configuration pending - it will complete on a later run." >&2
      return 3
    fi
  fi

  if [ -e "$mirror" ]; then
    local actual
    actual=$(git -C "$mirror" remote get-url origin 2>/dev/null || echo '<missing origin>')
    if ! remote_matches "$mirror" "$EXPECTED_MIRROR_REMOTE"; then
      echo "Refusing to adopt $mirror: origin is $actual, expected $EXPECTED_MIRROR_REMOTE (including push URLs)." >&2
      return 2
    fi
  else
    git clone --quiet "$EXPECTED_MIRROR_REMOTE" "$mirror" || {
      echo "Mirror clone pending - it will complete once Max has registered your key." >&2
      return 1
    }
  fi

  date -u +%FT%TZ > "$STATE/setup-complete"
  return 0
}
