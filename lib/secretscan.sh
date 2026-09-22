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
# Both hooks fail CLOSED: if the library cannot be sourced, the commit/push is refused rather
# than silently allowed through. Both scan the content that is actually about to leave this
# Mac - pre-commit reads each staged blob via `git show :<path>` (never the working-tree
# copy, which may differ from what's staged), and pre-push reads every blob touched by every
# commit in the push range (not just the tree of the final commit), so a secret introduced in
# an earlier commit and then edited away still blocks the push.
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
  git show ":$f" > "$tmp" 2>/dev/null
  if secret_scan_file "$tmp"; then
    rm -f "$tmp"
    printf 'refusing commit: %s looks like it contains a secret (a password or access key)\n' "$f" >&2
    exit 1
  fi
  rm -f "$tmp"
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
  while IFS= read -r commit; do
    while IFS= read -r -d '' f; do
      tmp=$(mktemp) || { echo "refusing push: could not scan $f" >&2; exit 1; }
      git show "$commit:$f" > "$tmp" 2>/dev/null
      if secret_scan_file "$tmp"; then
        rm -f "$tmp"
        printf 'refusing push: %s (commit %s) looks like it contains a secret (a password or access key)\n' "$f" "$commit" >&2
        exit 1
      fi
      rm -f "$tmp"
    done < <(git diff-tree -r --no-commit-id --diff-filter=ACMR --name-only -z "$commit")
  done < <(git rev-list "${range_args[@]}")
done
exit 0
HOOK
  if sed -i '' "s#__LIBDIR__#$libdir#" "$hooks/pre-commit" "$hooks/pre-push" 2>/dev/null; then :
  else sed -i "s#__LIBDIR__#$libdir#" "$hooks/pre-commit" "$hooks/pre-push"; fi
  chmod +x "$hooks/pre-commit" "$hooks/pre-push"
}
