#!/bin/bash
# AC-7: one place the secret patterns live. Used by commit_local (engine, unstages+logs+
# marks, never blocks the rest of the cycle) and by the pre-commit/pre-push hooks setup.sh
# installs into team/.git/hooks (hooks are not synced by git, so only local installation can
# plant them - a colleague's push can never disable this Mac's own gate).
SECRET_PATTERNS='-----BEGIN [A-Z ]*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|AIza[0-9A-Za-z_-]{35}'

# 0 (match) if the given file's content looks like it contains a secret.
secret_scan_file(){
  # -e marks the pattern explicitly: unguarded, "-----BEGIN..." is parsed as a grep option
  # instead of a pattern and every call fails with "unrecognized option".
  grep -qE -e "$SECRET_PATTERNS" -- "$1" 2>/dev/null
}
