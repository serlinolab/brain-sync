#!/bin/bash
# Resolve one working-tree path component by component, including intermediate links.
# Never follow an absolute target or step above the root, even if later components
# would lead back inside. Missing internal targets are safe; cycles fail closed.
_mirror_link_is_internal(){
  local root="$1" pending="$2" resolved="" part target hops=0
  while [ -n "$pending" ]; do
    part=${pending%%/*}
    if [ "$pending" = "$part" ]; then pending=""; else pending=${pending#*/}; fi
    case "$part" in
      ''|.) continue ;;
      ..)
        [ -n "$resolved" ] || return 1
        if [[ "$resolved" = */* ]]; then resolved=${resolved%/*}; else resolved=""; fi
        continue ;;
    esac
    if [ -L "$root/${resolved:+$resolved/}$part" ]; then
      hops=$((hops+1))
      [ "$hops" -le 40 ] || return 1
      # The suffix preserves target names ending in newlines in command substitution.
      target=$(readlink "$root/${resolved:+$resolved/}$part" && printf '.') || return 1
      target=${target%.}; target=${target%$'\n'}
      case "$target" in /*) return 1 ;; esac
      pending="$target${pending:+/$pending}"
    else
      resolved="${resolved:+$resolved/}$part"
    fi
  done
  # Git metadata is private even though it lives inside the checkout. Check after
  # resolving aliases and '..', including case variants on case-insensitive Macs.
  case "${resolved%%/*}" in .[gG][iI][tT]) return 1 ;; esac
  return 0
}

# Inspect the whole graph BEFORE unlinking anything: removing a chain's last link
# first would otherwise make its predecessors look like safe dangling links.
# Do not descend into .git or symlinked directories. NUL records preserve filenames.
sanitize_mirror_links(){
  local root="$1" list path parent relock rc=0
  local -a unsafe=()
  [ ! -L "$root" ] && [ -d "$root" ] || return 1
  root=$(cd "$root" && pwd -P) || return 1
  list=$(mktemp "${TMPDIR:-/tmp}/brain-links.XXXXXX") || return 1
  if ! find "$root" -path "$root/.git" -prune -o -type l -print0 > "$list"; then
    rm -f "$list"
    return 1
  fi
  while IFS= read -r -d '' path; do
    _mirror_link_is_internal "$root" "${path#"$root"/}" || unsafe+=("$path")
  done < "$list"
  rm -f "$list"
  for path in ${unsafe[@]+"${unsafe[@]}"}; do
    parent=${path%/*}; relock=0
    if [ ! -w "$parent" ]; then
      chmod u+w "$parent" || return 1
      relock=1
    fi
    if rm -- "$path"; then
      if declare -F log >/dev/null; then
        log "removed unsafe Brain symlink: ${path#"$root"/}"
      else
        printf 'removed unsafe Brain symlink: %s\n' "${path#"$root"/}" >&2
      fi
    else
      rc=1
    fi
    [ "$relock" -eq 0 ] || chmod u-w "$parent" || rc=1
  done
  return "$rc"
}

# Shared rebase machinery also serves team/, whose checkout policy is unchanged.
sanitize_brain_checkout(){
  [ -n "${BRAIN_SANITIZE_CHECKOUT:-}" ] || return 0
  sanitize_mirror_links "$BRAIN_SANITIZE_CHECKOUT"
}
