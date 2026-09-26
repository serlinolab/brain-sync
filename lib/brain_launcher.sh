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

# The launcher's whole AppleScript source. $1 = the Brain folder's real path. Every character
# either encoding leaves behind is URL-safe, so neither quote level below can be broken.
brain_launcher_script(){
  printf 'do shell script "open '\''claude://code/new?folder=%s&q=%s'\''"' \
    "$(brain_url_encode "$1")" "$(brain_url_encode "$BRAIN_LAUNCHER_PROMPT")"
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
  if [ -e "$app" ] || [ -L "$app" ]; then
    # Correct already: nothing to do. Anything else there was not built by this engine (or not
    # by this version of it) and is never deleted - moving it to the Trash is how to rebuild.
    [ "$(osadecompile "$app/Contents/Resources/Scripts/main.scpt" 2>/dev/null)" = "$script" ] \
      || log "$app is not the launcher this engine builds; leaving it alone"
    return 0
  fi
  mkdir -p "$HOME/Applications" || { log "could not create $HOME/Applications; skipping the Serlino Brain launcher"; return 0; }
  # Built beside its final name and moved into place, so a failed build never leaves a
  # half-made app that the check above would then refuse to replace.
  tmp="$HOME/Applications/.$BRAIN_LAUNCHER_NAME.building.$$.app"
  if osacompile -o "$tmp" -e "$script" >/dev/null 2>&1 && mv "$tmp" "$app"; then
    log "built the Serlino Brain launcher at $app"
  else
    rm -rf "$tmp"
    log "could not build the Serlino Brain launcher"
    return 0
  fi
  # ponytail: the Desktop shortcut is made only alongside a fresh build and never probed on
  # later cycles - a background job touching ~/Desktop is what can raise a macOS privacy
  # prompt, and a person who deleted the shortcut meant it. The app stays in Applications.
  if [ -d "$HOME/Desktop" ] && [ ! -e "$link" ] && [ ! -L "$link" ]; then
    ln -s "$app" "$link" 2>/dev/null || log "could not put the Serlino Brain launcher on the Desktop"
  fi
  return 0
}
