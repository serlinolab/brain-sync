#!/bin/bash
# Every Mac's sync status, from the `status/*` branches each one publishes to brain-team
# (lib/heartbeat.sh). Run by Max - or by Claude for him - from any Mac with `gh` signed in:
#   ./fleet-status.sh                 # one line per Mac
#   ./fleet-status.sh --full <name>   # one Mac's whole status, sync.log tail included
# A status older than FLEET_STALE_MINUTES means that Mac's cycles stopped (asleep, off, stuck).
set -u
REMOTE="${FLEET_REMOTE:-https://github.com/serlinolab/brain-team.git}"
FLEET_STALE_MINUTES="${FLEET_STALE_MINUTES:-90}"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
git init -q --bare "$work/r"
# gh supplies the credentials for the private repo; a local path (tests) needs none. Never prompt:
# without gh signed in, fail with a clear message instead of asking for a username.
export GIT_TERMINAL_PROMPT=0
case "$REMOTE" in https://*) gh auth status >/dev/null 2>&1 || { echo "sign in to GitHub first: gh auth login" >&2; exit 1; } ;; esac
if ! git -C "$work/r" -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
     fetch -q "$REMOTE" '+refs/heads/status/*:refs/heads/status/*' 2>"$work/err"; then
  echo "could not read brain-team: $(tail -1 "$work/err")" >&2; exit 1
fi
field(){ git -C "$work/r" show "status/$1:status.txt" 2>/dev/null | sed -n "s/^$2: //p" | head -1; }

if [ "${1:-}" = "--full" ]; then
  git -C "$work/r" show "status/${2:?usage: fleet-status.sh --full <name>}:status.txt"; exit $?
fi
names=$(git -C "$work/r" for-each-ref --format='%(refname:strip=3)' refs/heads/status/)
[ -n "$names" ] || { echo "no Mac has published a status yet"; exit 0; }
now=$(date -u +%s)
# The MAC column is as wide as the longest name (machine ids are LocalHostName + 4 hex, often 30+).
w=3; for n in $names; do [ ${#n} -gt "$w" ] && w=${#n}; done
printf "%-${w}s  %-14s %-36s %s\n" MAC AGE RESULT "ENGINE  LAUNCHER  APP  MACOS"
for n in $names; do
  updated=$(field "$n" updated)
  at=$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$updated" +%s 2>/dev/null || echo 0)
  mins=$(( (now - at) / 60 ))
  if [ "$at" -eq 0 ]; then age="unknown"
  elif [ "$mins" -lt 1 ]; then age="just now"
  else age="$mins min ago"; fi
  [ "$at" -eq 0 ] || [ "$mins" -gt "$FLEET_STALE_MINUTES" ] && age="$age STALE"
  printf "%-${w}s  %-14s %-36s %s  %s  %s  %s\n" "$n" "$age" "$(field "$n" result)" \
    "$(field "$n" engine)" "$(field "$n" launcher)" "$(field "$n" app)" "$(field "$n" macos)"
done
