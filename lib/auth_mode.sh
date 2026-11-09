#!/bin/bash
# Sign-in mode (MAX-2055). A Mac set up through the Serlino Brain app's "Sign in with MediaBuy"
# has no per-Mac SSH deploy keys: it reaches GitHub over HTTPS with a one-hour token that the
# app's credential helper gets from MediaBuy for the person's role (reader or editor). setup.sh
# records the mode in $STATE/auth-mode ("signin") and the helper in $STATE/credential-helper
# (the app's own executable). A Mac without that file keeps the SSH deploy keys, exactly as
# before: nothing changes for a Mac set up the old way.
#
# Sourced by lib/common.sh and lib/complete_setup.sh BEFORE they set their SSH defaults, so the
# HTTPS remotes become the expected ones (an explicit EXPECTED_*_REMOTE, as tests set, still wins).
# The helper reaches git through GIT_CONFIG_COUNT (command-level config): it applies to every git
# call of this process and its children, needs no write to any repo's config, and is appended
# after any GIT_CONFIG_* a caller already set. The empty value first resets every other helper
# (osxkeychain from the system config, a person's own), so the Brain token is never stored by them.
if [ -z "${_BRAIN_AUTH_MODE_LOADED:-}" ]; then
  _BRAIN_AUTH_MODE_LOADED=1
  _brain_auth_state="${STATE:-${BRAIN_ROOT:-$HOME/Serlinolab}/.state}"
  if [ "$(cat "$_brain_auth_state/auth-mode" 2>/dev/null)" = signin ]; then
    BRAIN_SIGNIN_MODE=1
    EXPECTED_TEAM_REMOTE="${EXPECTED_TEAM_REMOTE:-https://github.com/serlinolab/brain-team.git}"
    EXPECTED_MIRROR_REMOTE="${EXPECTED_MIRROR_REMOTE:-https://github.com/serlinolab/Serlinolab-Brain.git}"
    ONLINE_CHECK_REMOTE="${ONLINE_CHECK_REMOTE:-$EXPECTED_MIRROR_REMOTE}"
    HEARTBEAT_REMOTE="${HEARTBEAT_REMOTE:-origin}"
    _brain_helper=$(head -1 "$_brain_auth_state/credential-helper" 2>/dev/null)
    if [ -n "$_brain_helper" ] && [ -x "$_brain_helper" ]; then
      _n="${GIT_CONFIG_COUNT:-0}"
      case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
      export "GIT_CONFIG_KEY_$_n=credential.https://github.com.helper" "GIT_CONFIG_VALUE_$_n="
      _n=$((_n + 1))
      export "GIT_CONFIG_KEY_$_n=credential.https://github.com.helper" "GIT_CONFIG_VALUE_$_n=!\"$_brain_helper\" --git-credential"
      export GIT_CONFIG_COUNT=$((_n + 1))
    fi
    # A missing or signed-out helper must fail the git call, never wait on a password prompt.
    export GIT_TERMINAL_PROMPT=0
    unset _n _brain_helper
  fi
  unset _brain_auth_state
fi
