#!/bin/bash
# Single source of truth for the team/ sparse-checkout pattern (MAX-1515 review, Class A;
# amended when serlinolab/ moved beside team/, no longer nested inside it).
# Sourced by setup.sh (the real install) and tests/helpers.bash (test doubles), so the
# patterns a test asserts against can never drift from what setup.sh actually installs.
#
# `!.claude/` alone only excludes .claude when git considers it a directory - a colleague can
# commit `.claude` as a FILE or a SYMLINK and `git sparse-checkout check-rules --no-cone`
# still includes it. Excluding both the bare name and the trailing-slash form covers every
# object type regardless of how git classifies it.
write_team_sparse_checkout(){
  local team="$1"
  git -C "$team" sparse-checkout init --no-cone >/dev/null 2>&1 || return 1
  cat > "$team/.git/info/sparse-checkout" <<'EOF' || return 1
/*
!CLAUDE.md
!CLAUDE.local.md
!AGENTS.md
!.claude
!.claude/
EOF
  git -C "$team" sparse-checkout reapply >/dev/null 2>&1 || return 1
}
