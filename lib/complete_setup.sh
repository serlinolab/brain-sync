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

# MAX-1515 review, finding B: verifies team/'s REAL protection state instead of trusting
# $STATE/team-configured, which can survive a replacement directory that was never actually
# reconfigured (a marker written once and never re-checked against reality). Every check here
# mirrors exactly what complete_setup installs, through the same functions
# (write_team_sparse_checkout / install_team_hooks) that install them, so this can never
# silently drift from what a real setup does. Read-only: the scratch directory used to
# generate the expected hook bodies for comparison is never team/ itself.
#
# Also closes the dangling-symlink gap the review flagged separately: `-e` is false for a
# dangling symlink, so a check built only on `-e`/`-d` would treat one as "nothing here yet"
# and let a caller clone through it. `-L` catches a symlink whether or not its target exists.
team_is_protected(){
  local team="${1:-$ROOT/team}"
  [ -L "$team" ] && return 1
  [ -d "$team/.git" ] || return 1
  remote_matches "$team" "$EXPECTED_TEAM_REMOTE" || return 1
  [ "$(git -C "$team" config --bool core.sparseCheckout 2>/dev/null)" = true ] || return 1
  [ "$(git -C "$team" config --bool core.sparseCheckoutCone 2>/dev/null)" = false ] || return 1
  [ "$(cat "$team/.git/info/sparse-checkout" 2>/dev/null)" = "$(team_sparse_checkout_pattern)" ] || return 1
  [ "$(git -C "$team" config core.hooksPath 2>/dev/null)" = "$team/.git/hooks" ] || return 1
  [ "$(git -C "$team" config --bool core.symlinks 2>/dev/null)" = false ] || return 1
  [ -x "$team/.git/hooks/pre-commit" ] && [ -x "$team/.git/hooks/pre-push" ] || return 1
  _team_hooks_match "$team" || return 1
  return 0
}

# Generates the hook bodies complete_setup would install right now - same function
# (install_team_hooks), same libdir convention it always uses ($STATE/engine/lib) - into a
# scratch directory, and diffs them byte for byte against what is actually on disk. Never
# trusts a marker to say the hooks were ever really written, or that they still match after an
# upstream edit to secretscan.sh's templates.
_team_hooks_match(){
  local team="$1" libdir="$STATE/engine/lib" tmp rc=0
  tmp=$(mktemp -d) || return 1
  mkdir -p "$tmp/.git"
  install_team_hooks "$tmp" "$libdir" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  cmp -s "$team/.git/hooks/pre-commit" "$tmp/.git/hooks/pre-commit" || rc=1
  [ "$rc" -eq 0 ] && { cmp -s "$team/.git/hooks/pre-push" "$tmp/.git/hooks/pre-push" || rc=1; }
  rm -rf "$tmp"
  return "$rc"
}

# Lighter sibling for the read-only mirror: complete_setup does no further configuration on it
# beyond the clone itself (no sparse-checkout, no hooks) - sync_mirror's own protect_readonly
# is what guards it, re-applied every cycle regardless of this check.
mirror_is_ready(){
  local mirror="${1:-$ROOT/serlinolab}"
  [ -L "$mirror" ] && return 1
  [ -d "$mirror/.git" ] || return 1
  remote_matches "$mirror" "$EXPECTED_MIRROR_REMOTE"
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

  # MAX-1515 review, "also check": a dangling symlink at team/ is `-e` false but `-L` true - an
  # `-e`-only check below would read it as "nothing here yet" and clone straight through it.
  # Refuse outright, before anything else runs; never clone into/through it, never rm it.
  if [ -L "$team" ]; then
    echo "Refusing to use $team: it is a symlink, not a real folder." >&2
    return 2
  fi

  # MAX-1515 review, finding B: team_is_protected re-derives the real state instead of trusting
  # $STATE/team-configured - a marker that can survive a replacement clone which never actually
  # went through the configure step below.
  if team_is_protected "$team"; then
    team_ready=1
  elif [ -e "$team" ]; then
    local actual
    actual=$(git -C "$team" remote get-url origin 2>/dev/null || echo '<missing origin>')
    if remote_matches "$team" "$EXPECTED_TEAM_REMOTE"; then
      team_ready=1   # origin is right but the rest isn't (yet) protected - reconfigure below
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
      # MAX-1515 review, finding A: setup.sh and a background sync cycle both call
      # complete_setup, and until setup.sh also takes the lock (see setup.sh), the two could
      # reach this exact point together - both saw $team absent, both attempted the clone, one
      # lost. An unconditional rm -rf here deletes whichever side actually finished. Re-check
      # right before deleting: only remove what is NOT a real, matching clone - never blow away
      # one that is genuinely there now, however it got there.
      if remote_matches "$team" "$EXPECTED_TEAM_REMOTE"; then
        echo "$team was already completed elsewhere; leaving it in place." >&2
      else
        rm -rf "$team"
      fi
      echo "Team folder clone pending - it will complete once Max has registered your key." >&2
      return 1
    fi
  fi

  if [ "$team_ready" -eq 1 ] && ! team_is_protected "$team"; then
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

  if [ -L "$mirror" ]; then
    echo "Refusing to use $mirror: it is a symlink, not a real folder." >&2
    return 2
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
