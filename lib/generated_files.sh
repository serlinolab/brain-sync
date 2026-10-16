#!/bin/bash
# Write generated content without opening the destination for truncation. The producer is
# a command, not a pipeline, so a failed producer never publishes partial output. Temporary
# files live in the repo's Git directory, keeping interrupted writes out of git add -A
# while retaining an atomic rename on the same filesystem as these clones.
write_generated_file(){
  local dest="$1" tmp git_dir
  shift
  git_dir=$(git -C "$(dirname "$dest")" rev-parse --absolute-git-dir) || return 1
  if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -f "$dest" ]; }; then
    rm -rf -- "$dest" || return 1
  fi
  tmp=$(mktemp "$git_dir/.brain-sync.XXXXXX") || return 1
  if [ -f "$dest" ]; then
    # Preserve executable bits and other existing permissions for resolved conflict files.
    cp -p -- "$dest" "$tmp" && chmod u+w "$tmp" || { rm -f "$tmp"; return 1; }
  else
    chmod "$(printf '%o' "$((0666 & ~$(umask)))")" "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  if "$@" > "$tmp" && mv -fh -- "$tmp" "$dest"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}
