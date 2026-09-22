#!/bin/bash
# AC-7: one place the secret patterns live. Used by commit_local (engine, unstages+logs+
# marks, never blocks the rest of the cycle) and by the pre-commit/pre-push hooks setup.sh
# installs into team/.git/hooks (hooks are not synced by git, so only local installation can
# plant them - a colleague's push can never disable this Mac's own gate).
SECRET_PATTERNS='-----BEGIN [A-Z ]*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-(ant-|proj-)?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}'

# 0 (match) if the given file's content looks like it contains a secret.
secret_scan_file(){
  # -e marks the pattern explicitly: unguarded, "-----BEGIN..." is parsed as a grep option
  # instead of a pattern and every call fails with "unrecognized option".
  grep -qE -e "$SECRET_PATTERNS" -- "$1" 2>/dev/null
}

# Installs the local pre-commit/pre-push secret-scan hooks into $1 (a team/ checkout),
# pointing them at the library directory $2 (so `source` there finds this same
# secretscan.sh). Single source of truth for setup.sh (the real install) and tests, so a test
# can never assert against a hook body that setup.sh does not actually ship (Class B review,
# MAX-1515).
#
# Both hooks fail CLOSED on every error, not just a missing library: a scan that cannot run
# (grep itself erroring - exit status 2, distinct from "no match" at 1) refuses exactly like a
# match does; only an explicit "scanned, no match" (grep exit 0/1 respectively) lets a blob
# through. Same for a failing `git rev-list`/`git cat-file`/`git show` and an invalid range.
#
# pre-commit reads each staged blob via `git show :<path>` (never the working-tree copy,
# which may differ from what's staged). pre-push enumerates every BLOB OBJECT reachable from
# the pushed commits that the remote does not already have (`git rev-list --objects`, keeping
# only objects `git cat-file -t` reports as `blob`), not the tree of each commit via
# `diff-tree` - diff-tree's --diff-filter=ACMR misses type-change (T) commits, shows nothing
# for a root commit unless given --root, and shows nothing for a clean merge commit unless
# given -m. Object enumeration has none of those blind spots: every blob touched anywhere in
# the range is scanned once, regardless of which commit shape introduced it.
install_team_hooks(){
  local team="$1" libdir="$2"
  local hooks="$team/.git/hooks"
  mkdir -p "$hooks"
  cat > "$hooks/pre-commit" <<'HOOK' || return 1
#!/bin/bash
set -u
if ! source "__LIBDIR__/secretscan.sh" 2>/dev/null; then
  echo "refusing commit: the secret-scan library could not be loaded" >&2
  exit 1
fi
while IFS= read -r -d '' f; do
  tmp=$(mktemp) || { echo "refusing commit: could not scan $f" >&2; exit 1; }
  if ! git show ":$f" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    printf 'refusing commit: could not read the staged content of %s\n' "$f" >&2
    exit 1
  fi
  secret_scan_file "$tmp"; scan_rc=$?
  rm -f "$tmp"
  if [ "$scan_rc" -eq 0 ]; then
    printf 'refusing commit: %s looks like it contains a secret (a password or access key)\n' "$f" >&2
    exit 1
  fi
  if [ "$scan_rc" -ge 2 ]; then
    printf 'refusing commit: the secret scan itself failed on %s\n' "$f" >&2
    exit 1
  fi
done < <(git diff --cached --name-only -z --diff-filter=ACMR)
exit 0
HOOK
  cat > "$hooks/pre-push" <<'HOOK' || return 1
#!/bin/bash
set -u
if ! source "__LIBDIR__/secretscan.sh" 2>/dev/null; then
  echo "refusing push: the secret-scan library could not be loaded" >&2
  exit 1
fi
zero='0000000000000000000000000000000000000000'
while read -r local_ref local_sha remote_ref remote_sha; do
  [ "$local_sha" = "$zero" ] && continue
  if [ "$remote_sha" = "$zero" ]; then
    range_args=("$local_sha" --not --remotes)
  else
    range_args=("$remote_sha..$local_sha")
  fi
  if ! objects=$(git rev-list --objects "${range_args[@]}" 2>/dev/null); then
    printf 'refusing push: could not enumerate objects for %s\n' "$local_ref" >&2
    exit 1
  fi
  while IFS=' ' read -r sha label; do
    [ -n "$sha" ] || continue
    type=$(git cat-file -t "$sha" 2>/dev/null); cat_rc=$?
    if [ "$cat_rc" -ne 0 ]; then
      printf 'refusing push: could not inspect object %s\n' "$sha" >&2
      exit 1
    fi
    [ "$type" = blob ] || continue
    tmp=$(mktemp) || { echo "refusing push: could not scan object $sha" >&2; exit 1; }
    if ! git cat-file blob "$sha" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      printf 'refusing push: could not read object %s\n' "$sha" >&2
      exit 1
    fi
    secret_scan_file "$tmp"; scan_rc=$?
    rm -f "$tmp"
    if [ "$scan_rc" -eq 0 ]; then
      printf 'refusing push: %s looks like it contains a secret (a password or access key)\n' "${label:-$sha}" >&2
      exit 1
    fi
    if [ "$scan_rc" -ge 2 ]; then
      printf 'refusing push: the secret scan itself failed on %s\n' "${label:-$sha}" >&2
      exit 1
    fi
  done <<<"$objects"
done
exit 0
HOOK
  if sed -i '' "s#__LIBDIR__#$libdir#" "$hooks/pre-commit" "$hooks/pre-push" 2>/dev/null; then :
  else sed -i "s#__LIBDIR__#$libdir#" "$hooks/pre-commit" "$hooks/pre-push"; fi
  chmod +x "$hooks/pre-commit" "$hooks/pre-push"
}
