#!/usr/bin/env bats
# AC-6 - staleness must come from unsynced local work, checked before the
# network step, never from time-since-last-successful-cycle.
load 'helpers'
setup() { brain_test_setup; make_fake_personal_repo; }
teardown() { brain_test_teardown; }

@test "the attention marker appears when local work is unpushed and the network is down" {
  make_local_ahead_change
  STALE_HOURS=0 run_sync_cycle
  [ -f "$MARK" ]
}

@test "the attention marker does not appear when there is nothing to push" {
  STALE_HOURS=0 run_sync_cycle
  [ ! -f "$MARK" ]
}

@test "a backdated commit crosses the production threshold" {
  echo old > "$PERSONAL/old.txt"
  git -C "$PERSONAL" add old.txt
  GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' \
    git -C "$PERSONAL" -c user.name=fixture -c user.email=fixture@example.com commit -q -m old
  STALE_HOURS=4 run bash "$REPO_ROOT/sync.sh"
  [ -f "$MARK" ]
}

# Restored after Max lifted the diff cap: the two functional tests above prove
# the marker appears while offline, which already fails if stale_check is moved
# after the online() guard. They do NOT catch stale_check itself growing a
# network call - the regression AC-6 actually names ("evaluated BEFORE the
# network step"). That failure is static, so assert it statically.
@test "stale_check is ordered before the network guard and never touches the network itself" {
  local at_stale at_online
  at_stale=$(grep -nE '^\s*stale_check\b' "$REPO_ROOT/sync.sh" | head -1 | cut -d: -f1)
  at_online=$(grep -nE '^\s*if ! online\b' "$REPO_ROOT/sync.sh" | head -1 | cut -d: -f1)
  [ -n "$at_stale" ] && [ -n "$at_online" ]
  [ "$at_stale" -lt "$at_online" ]

  # the measurement itself lives in unsynced_age_hours now, so check BOTH bodies - a network
  # call moved into the helper would otherwise be invisible to this assertion
  run bash -c "sed -n '/^stale_check()/,/^}/p;/^unsynced_age_hours()/,/^}/p' '$REPO_ROOT/lib/sync.sh' | grep -nE 'fetch|push|pull|clone|ls-remote|curl|online'"
  [ "$status" -ne 0 ]
}
