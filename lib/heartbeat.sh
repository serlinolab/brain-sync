#!/bin/bash
# This Mac's status, published for remote checks (Max, 2026-10-03: "you must be able to check
# remotely too"). One file, status.txt, force-pushed as a single parentless commit to this Mac's
# own branch `status/<person>-<machine>` in brain-team - built with git plumbing in team/'s object
# store, so team/'s working tree, index and main are never touched, and the team's pre-push secret
# scan still checks it. Read with ./fleet-status.sh.
#
# Published when the cycle's result changes, or at least every HEARTBEAT_INTERVAL_SECONDS. A Mac
# whose cycles stop simply stops publishing: the age of its status is the signal. Nothing from
# personal/ is read; the log tail is the engine's own sync.log (which never contains file contents).
# Never fails the cycle; a failed push is logged once until one succeeds.
HEARTBEAT_INTERVAL_SECONDS="${HEARTBEAT_INTERVAL_SECONDS:-3600}"
HEARTBEAT_LOG_LINES=20

# A stable, unique name for this Mac's branch, chosen once and kept in $STATE/machine-id:
# `hostname -s` changes with the network (Bonjour renames it MacBook-Pro-2) and default names
# collide (two "MacBook-Air"s would overwrite each other's status). LocalHostName + 4 random hex.
heartbeat_machine(){
  local f="$STATE/machine-id" id
  id=$(cat "$f" 2>/dev/null)
  if [ -z "$id" ]; then
    id="$( (scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || echo mac) | tr -c 'A-Za-z0-9._\n-' '-')-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s\n' "$id" > "$f" 2>/dev/null
  fi
  printf '%s' "$id"
}

# $1 = this cycle's result, e.g. "ok" or "problem - mirror unreachable".
heartbeat_body(){
  local app="$HOME/Applications/SerlinoLab Brain.app" d v
  local IFS=:
  for d in ${BRAIN_APP_DIRS:-/Applications:$HOME/Applications}; do
    [ -f "$d/SerlinoLab Brain.app/Contents/Info.plist" ] && { app="$d/SerlinoLab Brain.app"; break; }
  done
  unset IFS
  v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || echo absent)
  printf 'person: %s\n' "$PERSON_SLUG"
  printf 'machine: %s\n' "$(heartbeat_machine)"
  printf 'updated: %s\n' "$(date -u +%FT%TZ)"
  printf 'result: %s\n' "$1"
  printf 'engine: %s\n' "$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --short HEAD 2>/dev/null || echo unknown)"
  if [ ! -f "$STATE/launcher.sh" ]; then printf 'launcher: missing\n'
  elif cmp -s "$STATE/launcher.sh" "$(dirname "${BASH_SOURCE[0]}")/launcher.sh"; then printf 'launcher: current\n'
  else printf 'launcher: outdated\n'; fi
  printf 'app: %s\n' "$v"
  printf 'app running: %s\n' "$(pgrep -x SerlinoLabBrain >/dev/null 2>&1 && echo yes || echo no)"
  printf 'macos: %s\n' "$(sw_vers -productVersion 2>/dev/null || echo unknown)"
  printf -- '--- last %s lines of sync.log\n' "$HEARTBEAT_LOG_LINES"
  tail -n "$HEARTBEAT_LOG_LINES" "$LOG" 2>/dev/null
}

publish_heartbeat(){
  local result="$1" last="$STATE/heartbeat-last" problem="$STATE/heartbeat-problem"
  # Only from a team/ that setup fully configured: its pre-push secret scan must be in place.
  team_is_protected 2>/dev/null || return 0
  local now prev_at=0 prev_result=""
  now=$(date +%s)
  [ -f "$last" ] && read -r prev_at prev_result < "$last"
  case "$prev_at" in ''|*[!0-9]*) prev_at=0 ;; esac
  if [ "$prev_result" = "$result" ] && [ $((now - prev_at)) -lt "$HEARTBEAT_INTERVAL_SECONDS" ]; then
    return 0
  fi
  local branch tmp blob tree commit remote
  branch="status/${PERSON_SLUG}-$(heartbeat_machine)"
  remote="${HEARTBEAT_REMOTE:-origin}"
  tmp=$(mktemp) || return 0
  heartbeat_body "$result" > "$tmp"
  if blob=$(git -C "$TEAM" hash-object -w "$tmp" 2>/dev/null) \
     && tree=$(printf '100644 blob %s\tstatus.txt\n' "$blob" | git -C "$TEAM" mktree 2>/dev/null) \
     && commit=$(GIT_AUTHOR_NAME="$GIT_IDENTITY_NAME" GIT_AUTHOR_EMAIL="$GIT_IDENTITY_EMAIL" \
                 GIT_COMMITTER_NAME="$GIT_IDENTITY_NAME" GIT_COMMITTER_EMAIL="$GIT_IDENTITY_EMAIL" \
                 git -C "$TEAM" commit-tree "$tree" -m "status $(date -u +%FT%TZ)" 2>/dev/null) \
     && git -C "$TEAM" push --quiet --force "$remote" "$commit:refs/heads/$branch" >/dev/null 2>"$tmp.err"; then
    printf '%s %s\n' "$now" "$result" > "$last" 2>/dev/null
    rm -f "$problem"
  else
    # Why, in one line: a secret-scan refusal must not look like a network failure.
    local why; why=$(grep -m1 'refusing push' "$tmp.err" 2>/dev/null || grep -v '^[[:space:]]*$' "$tmp.err" 2>/dev/null | tail -1)
    [ -e "$problem" ] || { : > "$problem"; log "could not publish this Mac's status to brain-team ($branch): ${why:-no error output}"; }
  fi
  rm -f "$tmp.err"
  rm -f "$tmp"
  return 0
}
