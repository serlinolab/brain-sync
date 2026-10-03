#!/bin/bash
# Keeps the INSTALLED launcher ($STATE/launcher.sh, what launchd runs) equal to this engine's
# lib/launcher.sh. setup.sh copied it once and nothing ever refreshed it, so no launcher change
# had reached a Mac before this (MAX-1629, 2026-10-03). Sourced by sync.sh, which runs only after
# the launcher's self-update proved this engine copy with `bash -n` and `sync.sh --selfcheck`.
#
# The launcher is what rolls a broken engine back, so it is replaced only with a copy that parses,
# and by rename: the bash running the old one keeps reading its old file, untouched. A Mac with
# no installed launcher is left to setup.sh. Never fails the cycle.
LAUNCHER_SOURCE="${LAUNCHER_SOURCE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/launcher.sh}"

ensure_launcher_current(){
  local dst="$STATE/launcher.sh" problem="$STATE/launcher-refresh-problem" tmp
  [ -f "$LAUNCHER_SOURCE" ] && [ -f "$dst" ] || return 0
  cmp -s "$LAUNCHER_SOURCE" "$dst" && return 0
  if ! bash -n "$LAUNCHER_SOURCE" 2>/dev/null; then
    [ -e "$problem" ] || { : > "$problem"; log "the engine's launcher does not parse; keeping the installed one"; }
    return 0
  fi
  tmp="$dst.new.$$"
  # The replaced one is kept beside it (launcher.sh.prev): the launcher is what rolls a broken
  # engine back, so a launcher that parses but misbehaves has no automatic way back - this file is
  # the manual one (`cp launcher.sh.prev launcher.sh`).
  cp -p "$dst" "$dst.prev" 2>/dev/null
  if install -m 0755 "$LAUNCHER_SOURCE" "$tmp" 2>/dev/null && mv -f "$tmp" "$dst" 2>/dev/null; then
    rm -f "$problem"
    log "updated the installed launcher"
  else
    rm -f "$tmp"
    [ -e "$problem" ] || { : > "$problem"; log "could not update the installed launcher"; }
  fi
  return 0
}
