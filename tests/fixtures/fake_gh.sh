#!/bin/bash
# Test fixture: a minimal stand-in for the `gh` CLI, covering only the calls provision.sh
# makes. State lives under $FAKE_GH_STATE as plain files so a test can inspect it directly
# instead of re-parsing fake JSON.
#
# Failure-simulation knobs (env vars a test sets before calling provision.sh):
#   FAKE_GH_FAIL_KEYS_LOOKUP=1        - `api repos/*/*/keys` GET exits 1 (transient API failure)
#   FAKE_GH_PAGE_SIZE=<n>             - caps a keys listing to <n> rows unless --paginate is passed
#                                        (default 30, GitHub's real default page size)
set -u
STATE="${FAKE_GH_STATE:?FAKE_GH_STATE must be set}"
PAGE_SIZE="${FAKE_GH_PAGE_SIZE:-30}"
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
    paginate=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -X) shift; method="$1" ;;
        -f|-F) shift; fields+=("$1") ;;
        --jq) shift; jqexpr="$1" ;;
        --paginate) paginate=1 ;;
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
          [ "${FAKE_GH_FAIL_KEYS_LOOKUP:-0}" = 1 ] && exit 1
          local_rows() { if [ "$paginate" = 1 ]; then cat "$keyfile"; else head -n "$PAGE_SIZE" "$keyfile"; fi; }
          if [ -n "$jqexpr" ]; then
            case "$jqexpr" in
              *'@tsv'*) local_rows ;;
              *'select(.title=='*)
                want=$(printf '%s' "$jqexpr" | sed -nE 's/.*select\(\.title=="([^"]*)"\).*/\1/p')
                local_rows | awk -F'\t' -v t="$want" '$1==t{print $2}'
                ;;
              *'select(.key=='*)
                want=$(printf '%s' "$jqexpr" | sed -nE 's/.*select\(\.key=="([^"]*)"\).*/\1/p')
                local_rows | awk -F'\t' -v k="$want" '$2==k{print $1}'
                ;;
            esac
          else
            local_rows
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
        readmefile="$STATE/repos/${org}__${repo}.readme"
        if [ "$method" = GET ]; then
          [ -e "$readmefile" ] && exit 0 || exit 1
        else
          touch "$readmefile"
          exit 0
        fi
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
