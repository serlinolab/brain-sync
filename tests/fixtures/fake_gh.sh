#!/bin/bash
# Test fixture: a minimal stand-in for the `gh` CLI, covering only the calls provision.sh
# makes. State lives under $FAKE_GH_STATE as plain files so a test can inspect it directly
# instead of re-parsing fake JSON.
set -u
STATE="${FAKE_GH_STATE:?FAKE_GH_STATE must be set}"
mkdir -p "$STATE/repos"

cmd="${1:-}"; shift || true

case "$cmd" in
  repo)
    sub="${1:-}"; shift || true
    case "$sub" in
      create)
        orgrepo="$1"
        touch "$STATE/repos/${orgrepo//\//__}"
        exit 0
        ;;
      *) exit 1 ;;
    esac
    ;;
  api)
    method=""
    path=""
    fields=()
    jqexpr=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -X) shift; method="$1" ;;
        -f|-F) shift; fields+=("$1") ;;
        --jq) shift; jqexpr="$1" ;;
        *) [ -z "$path" ] && path="$1" ;;
      esac
      shift
    done
    if [ -z "$method" ]; then
      if [ "${#fields[@]}" -gt 0 ]; then method=POST; else method=GET; fi
    fi
    case "$path" in
      repos/*/*/keys)
        org=$(echo "$path" | cut -d/ -f2); repo=$(echo "$path" | cut -d/ -f3)
        keyfile="$STATE/repos/${org}__${repo}.keys"
        touch "$keyfile"
        if [ "$method" = GET ]; then
          if [ -n "$jqexpr" ]; then
            case "$jqexpr" in
              *'select(.title=='*)
                want=$(printf '%s' "$jqexpr" | sed -nE 's/.*select\(\.title=="([^"]*)"\).*/\1/p')
                awk -F'\t' -v t="$want" '$1==t{print $2}' "$keyfile"
                ;;
              *'select(.key=='*)
                want=$(printf '%s' "$jqexpr" | sed -nE 's/.*select\(\.key=="([^"]*)"\).*/\1/p')
                awk -F'\t' -v k="$want" '$2==k{print $1}' "$keyfile"
                ;;
            esac
          else
            cat "$keyfile"
          fi
          exit 0
        else
          title="" key="" ro="false"
          for f in "${fields[@]}"; do
            case "$f" in
              title=*) title="${f#title=}" ;;
              key=*) key="${f#key=}" ;;
              read_only=*) ro="${f#read_only=}" ;;
            esac
          done
          printf '%s\t%s\t%s\n' "$title" "$key" "$ro" >> "$keyfile"
          exit 0
        fi
        ;;
      repos/*/*/contents/*)
        org=$(echo "$path" | cut -d/ -f2); repo=$(echo "$path" | cut -d/ -f3)
        touch "$STATE/repos/${org}__${repo}"
        exit 0
        ;;
      repos/*/*)
        org=$(echo "$path" | cut -d/ -f2); repo=$(echo "$path" | cut -d/ -f3)
        [ -e "$STATE/repos/${org}__${repo}" ] && exit 0 || exit 1
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
