#!/bin/bash
# The "Serlino Brain" launcher - our copy of Parker Desktop's "Work on this" button. A one-line
# AppleScript app in ~/Applications that opens the Claude desktop app's Code tab on
# Serlinolab_Brain/ with "get started" typed in but not sent, through Claude's documented deep
# link (https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link). Claude
# always asks "Trust workspace" for a folder that arrives by link; that cannot be switched off.
#
# Sourced by setup.sh and sync.sh. ensure_brain_launcher runs every cycle, the same self-heal as
# the folders (complete_setup), so a Mac set up before this shipped gets the launcher on its next
# sync. It never fails its caller: every problem is logged and skipped.
CLAUDE_APP="${CLAUDE_APP:-/Applications/Claude.app}"
BRAIN_LAUNCHER_NAME="Serlino Brain"
BRAIN_LAUNCHER_PROMPT="get started"
# The script an app was built from, kept as an extended attribute on the bundle so the every-
# cycle check is one read, not a decompile. Not a file inside the bundle: osacompile signs the
# app, and any file added under Contents/ breaks that seal ("a sealed resource is missing or
# invalid"); an attribute on the bundle folder leaves `codesign --verify --strict` passing.
BRAIN_LAUNCHER_STAMP_ATTR="com.serlinolab.launcher-script"

# Percent-encodes every byte except RFC 3986's unreserved characters. Byte-wise through od,
# because bash 3.2's `printf "'c"` reports a byte above 0x7F as a negative number.
brain_url_encode(){
  local b c out=""
  for b in $(printf '%s' "$1" | od -An -v -tx1); do
    c=$(printf '%b' "\\x$b")
    case "$c" in
      [A-Za-z0-9._~-]) out+="$c" ;;
      *) out+="%$(printf '%s' "$b" | tr '[:lower:]' '[:upper:]')" ;;
    esac
  done
  printf '%s' "$out"
}

# What one click runs, as /bin/sh. $1 = the Brain folder's real path.
#
# claude-code#92210 (open upstream; Parker Desktop shipped the same workaround): Claude compares
# the link's folder= with the folder already selected, and on a match opens a scratch session
# instead - so every click after the first used to land in scratch. Two spellings of the same
# folder, without and with a trailing /, are alternated click by click; missing or unreadable
# state means the plain one. The state sits beside the Brain ($ROOT/.launcher-last), never in
# the read-only Brain folder, team/ or personal/. Drop the alternation once #92210 is fixed.
brain_launcher_shell(){
  local folder state q
  folder=$(brain_url_encode "$1")
  state=$(printf '%s' "${1%/*}/.launcher-last" | sed "s/'/'\\\\''/g")
  q=$(brain_url_encode "$BRAIN_LAUNCHER_PROMPT")
  printf '%s' "f='$state'; if [ \"\$(cat \"\$f\" 2>/dev/null)\" = plain ]; then s=slash; d=${folder}%2F; else s=plain; d=$folder; fi; { echo \"\$s\" > \"\$f\"; } 2>/dev/null; open \"claude://code/new?folder=\$d&q=$q\""
}

# The launcher's whole AppleScript source: one `do shell script` line, with the shell escaped
# for an AppleScript string literal (backslash and double quote are its only escapes).
brain_launcher_script(){
  printf 'do shell script "%s"' "$(brain_launcher_shell "$1" | sed -e 's/[\\"]/\\&/g')"
}

ensure_brain_launcher(){
  local brain script tmp
  local app="$HOME/Applications/$BRAIN_LAUNCHER_NAME.app" link="$HOME/Desktop/$BRAIN_LAUNCHER_NAME.app"
  # Not cloned yet: setup is still pending, and a later cycle builds the launcher once it lands.
  brain=$(cd "$ROOT/Serlinolab_Brain" 2>/dev/null && pwd -P) || return 0
  if [ ! -d "$CLAUDE_APP" ]; then
    log "the Claude app is not installed at $CLAUDE_APP; skipping the Serlino Brain launcher"
    return 0
  fi
  script=$(brain_launcher_script "$brain")
  local old="" stamp
  if [ -e "$app" ] || [ -L "$app" ]; then
    # Stamp matches: nothing to do. A different stamp is an older launcher of ours, rebuilt once
    # below. No stamp at all: not built by this engine, never touched - Trash it to rebuild.
    if ! stamp=$(xattr -p "$BRAIN_LAUNCHER_STAMP_ATTR" "$app" 2>/dev/null); then
      log "$app is not the launcher this engine builds; leaving it alone"
      return 0
    fi
    [ "$stamp" = "$script" ] && return 0
    old="$HOME/Applications/.$BRAIN_LAUNCHER_NAME.old.$$.app"
  fi
  mkdir -p "$HOME/Applications" || { log "could not create $HOME/Applications; skipping the Serlino Brain launcher"; return 0; }
  # Built beside its final name and moved into place, so a failed build never leaves a
  # half-made app that the check above would then refuse to replace.
  tmp="$HOME/Applications/.$BRAIN_LAUNCHER_NAME.building.$$.app"
  if ! osacompile -o "$tmp" -e "$script" >/dev/null 2>&1 \
     || ! xattr -w "$BRAIN_LAUNCHER_STAMP_ATTR" "$script" "$tmp" 2>/dev/null; then
    rm -rf "$tmp"
    log "could not build the Serlino Brain launcher"
    return 0
  fi
  # Our older launcher steps aside only now that its replacement is built, and comes back if the
  # move below does not happen.
  if [ -n "$old" ] && ! mv "$app" "$old"; then
    rm -rf "$tmp"
    log "could not replace the older Serlino Brain launcher"
    return 0
  fi
  # Both callers hold the sync lock, so nothing should race this. Belt and braces anyway: BSD mv
  # has no "never into a folder" flag, and onto an app that appeared meanwhile it would put the
  # temp app INSIDE that bundle. Re-check right before the move, and if a winner still slipped
  # in, take our own temp back out of it - never touching anything else in there.
  if [ -e "$app" ] || [ -L "$app" ] || ! mv "$tmp" "$app"; then
    rm -rf "$tmp"
    [ -n "$old" ] && [ ! -e "$app" ] && mv "$old" "$app"
    log "the Serlino Brain launcher appeared while building; keeping the one already there"
    return 0
  fi
  if [ -e "$app/${tmp##*/}" ]; then
    rm -rf "${app:?}/${tmp##*/}"
    log "the Serlino Brain launcher appeared while building; keeping the one already there"
    return 0
  fi
  if [ -n "$old" ]; then
    rm -rf "$old"
    log "rebuilt the Serlino Brain launcher at $app (its script changed)"
    return 0   # the Desktop shortcut, if the person kept it, already points here
  fi
  log "built the Serlino Brain launcher at $app"
  # ponytail: the Desktop shortcut is made only alongside a fresh build and never probed on
  # later cycles - a background job touching ~/Desktop is what can raise a macOS privacy
  # prompt, and a person who deleted the shortcut meant it. The app stays in Applications.
  if [ -d "$HOME/Desktop" ] && [ ! -e "$link" ] && [ ! -L "$link" ]; then
    ln -s "$app" "$link" 2>/dev/null || log "could not put the Serlino Brain launcher on the Desktop"
  fi
  return 0
}
