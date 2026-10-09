#!/usr/bin/env bats
# MAX-1790 - the Brain as a two-way folder. A Mac whose deploy key may push to Serlinolab-Brain
# edits it directly: a save to an unprotected file is committed under that person and reaches
# every other Mac; protected paths (lib/protected_paths.sh) stay read-only, are never committed,
# and any text written into one is kept aside. A Mac whose key is read-only keeps today's
# mirror behaviour and never loses what it had written. The team/ safeguards (secret scan,
# size limit, OS junk, union merge, parked binary conflicts, autostash check, remote-match check,
# offline commit) apply to the Brain too.
load 'helpers'

setup() { brain_test_setup; make_writable_brain; }
teardown() {
  [ -n "${ROOT2:-}" ] && chmod -R u+w "$ROOT2" 2>/dev/null
  [ -n "${ROOT2:-}" ] && rm -rf "$ROOT2"
  brain_test_teardown
}

origin() { git -C "$BRAIN_ROOT/origin-mirror.git" "$@"; }
# an editor that saves by replacing the file, which a read-only FILE does not stop
edit_protected() { chmod u+w "$(dirname "$MIRROR/$1")" 2>/dev/null; printf '%s\n' "$2" > "$MIRROR/$1.new" && mv -f "$MIRROR/$1.new" "$MIRROR/$1"; }

PROTECTED_PATHS=(AGENTS.md CLAUDE.md a/b/AGENTS.md notes/CLAUDE.local.md .claude/skills/hooks/SKILL.md
  .claude/rules/new.md .claude/new.md x/.claude/skills/s/SKILL.md .agents/y/z.md .agents method/README.md
  method/craft/scriptwriting.md audits/latest-weekly.md company/stock-status.md competitors/README.md
  voice-of-customer/corpus-profile.md voice-of-customer/phrase-bank-it.md voice-of-customer/phrase-bank-us.md
  voice-of-customer/support-requests.md)
# MAX-1790: Macs mount case-insensitively, so these load as instructions / hit the same files.
# GitHub's ruleset folds case too (verified 2026-10-09), so the engine does.
CASE_VARIANT_PATHS=(claude.md notes/claude.md notes/Agents.md company/agents.md notes/Claude.Local.md
  .CLAUDE/skills/x/SKILL.md x/.Agents/y.md Method/x.md METHOD/README.md Audits/Latest-Weekly.md
  Company/Stock-Status.md Voice-Of-Customer/Phrase-Bank-IT.md)
OPEN_PATHS=(company/brand-rules.md running-notes/max-1790-probe.md docs/method/x.md methods/x.md
  company/CLAUDE.md.bak voice-of-customer/phrase-bank-fr.md)

# --- the rule itself -------------------------------------------------------------------------

@test "the protected-path rule refuses the 18 ruleset paths and their case variants, and lets ordinary pages through" {
  source "$REPO_ROOT/lib/protected_paths.sh"
  local p
  for p in "${PROTECTED_PATHS[@]}" "${CASE_VARIANT_PATHS[@]}"; do brain_path_protected "$p" || { echo "should be protected: $p"; false; }; done
  for p in "${OPEN_PATHS[@]}"; do ! brain_path_protected "$p" || { echo "should be open: $p"; false; }; done
}

@test "the git add exclude pathspecs agree with the predicate, path for path" {
  source "$REPO_ROOT/lib/protected_paths.sh"
  local r="$BRAIN_ROOT/pathspec-check" p
  git init -q "$r"
  for p in "${PROTECTED_PATHS[@]}" "${CASE_VARIANT_PATHS[@]}" "${OPEN_PATHS[@]}"; do
    [ "$p" = .agents ] && continue   # the symlink itself is covered by the .agents/y/z.md case below
    mkdir -p "$r/$(dirname "$p")"; echo x > "$r/$p"
  done
  local -a specs=()
  while IFS= read -r p; do specs+=("$p"); done < <(brain_protected_excludes)
  git -C "$r" add -A -- . "${specs[@]}"
  local staged; staged=$(git -C "$r" diff --cached --name-only)
  # -i: on a case-insensitive volume git records a variant under the spelling already on disk
  for p in "${PROTECTED_PATHS[@]}" "${CASE_VARIANT_PATHS[@]}"; do
    [ "$p" = .agents ] && continue
    ! grep -qixF "$p" <<<"$staged" || { echo "staged although protected: $p"; false; }
  done
  for p in "${OPEN_PATHS[@]}"; do grep -qxF "$p" <<<"$staged" || { echo "not staged although open: $p"; false; }; done
}

# --- two-way ---------------------------------------------------------------------------------

@test "a save to an unprotected file reaches origin under this person, and the other Mac the cycle after" {
  setup_second_brain_mac
  echo "new rule" >> "$MIRROR/company/brand-rules.md"
  mkdir -p "$MIRROR/running-notes"; echo probe > "$MIRROR/running-notes/max-1790-probe.md"
  run_sync_cycle
  origin show main:company/brand-rules.md | grep -q "new rule"
  origin show main:running-notes/max-1790-probe.md >/dev/null
  [ "$(origin log -1 --format=%an)" = "Serlino Brain (testperson)" ]
  [[ "$(origin log -1 --format=%ae)" == brain-testperson@* ]] || false
  [ -z "$(git -C "$MIRROR" status --porcelain)" ]            # the signpost is not an uncommitted change
  ! origin ls-tree -r --name-only main | grep -q "READ ME FIRST" || false
  grep -q "Save a change here" "$MIRROR/READ ME FIRST.txt"
  [ -f "$ROOT/what-changed.md" ]

  run_second_mac_sync_cycle
  grep -q "new rule" "$ROOT2/Serlinolab_Brain/company/brand-rules.md"
  echo "from karl" > "$ROOT2/Serlinolab_Brain/company/karl.md"
  run_second_mac_sync_cycle
  run_sync_cycle
  grep -q "from karl" "$MIRROR/company/karl.md"
  [ "$(origin log -1 --format=%an)" = "Serlino Brain (karl)" ]
}

@test "everything except the protected paths is writable, and the protected ones refuse a plain write" {
  touch "$MIRROR/company/x.md" "$MIRROR/root-file.md"; mkdir "$MIRROR/company/newdir"
  echo more >> "$MIRROR/company/brand-rules.md"
  run bash -c "echo x >> '$MIRROR/CLAUDE.md'" 2>/dev/null;       [ "$status" -ne 0 ]
  run bash -c "echo x >> '$MIRROR/method/README.md'" 2>/dev/null; [ "$status" -ne 0 ]
  run bash -c "touch '$MIRROR/method/new.md'" 2>/dev/null;        [ "$status" -ne 0 ]
  run bash -c "touch '$MIRROR/.claude/new.md'" 2>/dev/null;       [ "$status" -ne 0 ]
  run bash -c "echo x >> '$MIRROR/company/stock-status.md'" 2>/dev/null; [ "$status" -ne 0 ]
  run_sync_cycle
  # still so after a cycle that fetched, rebased and committed
  run bash -c "echo x >> '$MIRROR/CLAUDE.md'" 2>/dev/null;       [ "$status" -ne 0 ]
  touch "$MIRROR/company/y.md"
}

@test "a protected edit is kept aside, put back, never committed, and the person is told in plain words" {
  local before; before=$(origin rev-parse main)
  edit_protected CLAUDE.md "my rule"
  edit_protected method/README.md "my method"
  chmod u+w "$MIRROR/.claude"; echo new > "$MIRROR/.claude/new.md"
  rm -f "$MIRROR/company/stock-status.md"
  echo "a real note" >> "$MIRROR/company/brand-rules.md"
  run run_sync_cycle
  [ "$status" -eq 0 ]
  [ "$(origin diff --name-only "$before" main)" = "company/brand-rules.md" ]    # only the open page went out
  [ "$(cat "$MIRROR/CLAUDE.md")" = "$(origin show main:CLAUDE.md)" ]
  [ "$(cat "$MIRROR/method/README.md")" = "$(origin show main:method/README.md)" ]
  [ ! -e "$MIRROR/.claude/new.md" ]
  [ -e "$MIRROR/company/stock-status.md" ]
  [ -z "$(git -C "$MIRROR" status --porcelain)" ]
  local kept; kept=$(ls -d "$STATE"/protected-edits/*)
  [ "$(cat "$kept/CLAUDE.md")" = "my rule" ]
  [ "$(cat "$kept/method/README.md")" = "my method" ]
  [ "$(cat "$kept/.claude/new.md")" = "new" ]
  grep -q "locked page" "$MARK"
  grep -qF "$STATE/protected-edits/" "$MARK"
  ! grep -qiwE 'git|commit|rebase|ruleset|push|branch' "$MARK" || false
  run bash -c "echo x >> '$MIRROR/CLAUDE.md'" 2>/dev/null; [ "$status" -ne 0 ]    # locked again
  run bash -c "touch '$MIRROR/method/n.md'" 2>/dev/null;   [ "$status" -ne 0 ]
}

@test "case variants of instruction files are kept aside too, never shared, never silent" {
  chmod u+w "$MIRROR/.claude" "$MIRROR/.claude/skills"   # someone overriding the lock, as on a Mac
  mkdir -p "$MIRROR/notes" "$MIRROR/.CLAUDE/skills/x"
  echo "lower" > "$MIRROR/notes/claude.md"; echo "agents" > "$MIRROR/company/agents.md"
  echo "skill" > "$MIRROR/.CLAUDE/skills/x/SKILL.md"; echo "open" > "$MIRROR/company/open.md"
  run_sync_cycle
  origin show main:company/open.md >/dev/null
  ! origin ls-tree -r --name-only main | grep -qi 'notes/claude.md\|agents.md\|skills/x' || false
  [ ! -e "$MIRROR/notes/claude.md" ]
  [ ! -e "$MIRROR/company/agents.md" ]
  [ "$(cat "$STATE"/protected-edits/*/notes/claude.md)" = lower ]
  [ "$(cat "$STATE"/protected-edits/*/company/agents.md)" = agents ]
  grep -q "locked page" "$MARK"
}

@test "the git add exclusion alone keeps a protected edit out of a commit, whatever the restore step did" {
  # second layer: _commit_repo is called WITHOUT brain_keep_protected_edits having run first
  edit_protected CLAUDE.md "my rule"; edit_protected method/README.md "my method"
  mkdir -p "$MIRROR/x/.claude"; echo new > "$MIRROR/x/.claude/n.md"
  echo "open" > "$MIRROR/company/open.md"
  run bash -c "source '$REPO_ROOT/lib/common.sh'; source '$REPO_ROOT/lib/secretscan.sh'; \
    source '$REPO_ROOT/lib/team_layout.sh'; source '$REPO_ROOT/lib/complete_setup.sh'; \
    source '$REPO_ROOT/lib/sync.sh'; _commit_repo '$MIRROR' brain"
  [ "$status" -eq 0 ]
  [ "$(git -C "$MIRROR" show --name-only --format= HEAD)" = "company/open.md" ]
}

@test "the .agents symlink is protected as a path: replacing it is undone" {
  rm -f "$MIRROR/.agents"; echo "not a link" > "$MIRROR/.agents"
  run_sync_cycle
  [ -L "$MIRROR/.agents" ]
  [ "$(origin ls-tree main .agents | cut -c1-6)" = 120000 ]
  [ -n "$(find "$STATE/protected-edits" -name .agents)" ]
}

@test "the generated signpost is never committed, and the cycle after still sends nothing for it" {
  run_sync_cycle; run_sync_cycle
  ! origin ls-tree -r --name-only main | grep -q "READ ME FIRST" || false
}

# --- the ruleset as a second layer ------------------------------------------------------------

@test "a push the ruleset refuses is rebuilt without the protected part, tried once more, and the rest lands" {
  install_ruleset_hook
  chmod u+w "$MIRROR/CLAUDE.md"; echo hacked >> "$MIRROR/CLAUDE.md"; echo ok > "$MIRROR/company/new-ok.md"
  git -C "$MIRROR" add -A; git_commit "$MIRROR" "made by hand: protected and open together"
  run_sync_cycle
  origin show main:company/new-ok.md | grep -q ok
  ! origin show main:CLAUDE.md | grep -q hacked || false
  ! grep -q hacked "$MIRROR/CLAUDE.md" || false
  grep -rq hacked "$STATE/protected-edits"
  grep -q "GitHub refused protected Brain paths" "$LOG"
  [ "$(cat "$BRAIN_ROOT/origin-mirror.git/pre-receive-calls" | wc -l | tr -d ' ')" = 2 ]   # one refusal, one success
  run_sync_cycle; run_sync_cycle
  [ "$(cat "$BRAIN_ROOT/origin-mirror.git/pre-receive-calls" | wc -l | tr -d ' ')" = 2 ]   # and never again
}

@test "a refusal the engine cannot repair is parked: the same commits are not pushed cycle after cycle" {
  install_ruleset_hook refuse-everything
  echo "an open page" > "$MIRROR/company/open.md"
  run run_sync_cycle                               # commits, pushes once, is refused
  [ "$status" -ne 0 ]
  local calls; calls=$(wc -l < "$BRAIN_ROOT/origin-mirror.git/pre-receive-calls" | tr -d ' ')
  [ "$calls" = 1 ]
  run run_sync_cycle; run run_sync_cycle
  [ "$(wc -l < "$BRAIN_ROOT/origin-mirror.git/pre-receive-calls" | tr -d ' ')" = "$calls" ]
  grep -q "not pushing them again" "$LOG"
  [ "$(git -C "$MIRROR" rev-list --count origin/main..HEAD)" = 1 ]   # the person's work is still there
  # something changes upstream and the cause is fixed: it goes out again by itself
  rm "$BRAIN_ROOT/origin-mirror.git/hooks/pre-receive"
  local other; other=$(mktemp -d); git clone -q "$BRAIN_ROOT/origin-mirror.git" "$other"
  echo "colleague" > "$other/company/c.md"; git -C "$other" add -A; git_commit "$other" colleague; git -C "$other" push -q origin main
  rm -rf "$other"
  run_sync_cycle
  origin show main:company/open.md | grep -q "an open page"
}

# --- read-only: today's behaviour, and no lost text ---------------------------------------------

@test "a key that goes back to read-only: unsent work is kept in brain-unsent, then the folder mirrors origin again" {
  echo "committed but unsent" >> "$MIRROR/sub/file.txt"; git -C "$MIRROR" add -A; git_commit "$MIRROR" unsent
  echo "dirty" > "$MIRROR/company/brand-rules.md"
  echo "brand new" > "$MIRROR/company/fresh.md"
  make_brain_readonly
  run_sync_cycle
  [ "$(git -C "$MIRROR" rev-parse HEAD)" = "$(origin rev-parse main)" ]
  [ ! -e "$MIRROR/company/fresh.md" ]
  [ ! -e "$STATE/brain-writable" ]
  run bash -c "echo x > '$MIRROR/company/z.md'" 2>/dev/null; [ "$status" -ne 0 ]
  local d; d=$(ls -d "$STATE"/brain-unsent/*)
  grep -q dirty "$d/files/company/brand-rules.md"
  grep -q "brand new" "$d/files/company/fresh.md"
  grep -q "committed but unsent" "$d/files/sub/file.txt"
  grep -q "committed but unsent" "$d/changes.patch"
  grep -q "can no longer change" "$MARK"
  ! origin show main:sub/file.txt | grep -q "committed but unsent" || false
  run_sync_cycle                                    # a second read-only cycle keeps nothing new
  [ "$(ls "$STATE/brain-unsent" | wc -l | tr -d ' ')" = 1 ]
}

@test "a read-only Mac that never wrote anything keeps nothing and behaves as the mirror always did" {
  make_brain_readonly
  run_sync_cycle
  [ ! -d "$STATE/brain-unsent" ] || [ -z "$(ls -A "$STATE/brain-unsent")" ]
  [ ! -f "$MARK" ]
  run bash -c "echo hi > '$MIRROR/sub/newfile.txt'" 2>/dev/null; [ "$status" -ne 0 ]
  run bash -c "echo hi >> '$MIRROR/CLAUDE.md'" 2>/dev/null; [ "$status" -ne 0 ]
  grep -q "Save it in the team folder" "$MIRROR/READ ME FIRST.txt"
}

@test "upgrading the key switches a read-only mirror to editable on the next cycle, with protected paths still locked" {
  make_brain_readonly; run_sync_cycle
  run bash -c "echo hi > '$MIRROR/company/z.md'" 2>/dev/null; [ "$status" -ne 0 ]
  make_brain_writable; run_sync_cycle
  [ -e "$STATE/brain-writable" ]
  echo hi > "$MIRROR/company/z.md"
  run bash -c "echo x >> '$MIRROR/CLAUDE.md'" 2>/dev/null; [ "$status" -ne 0 ]
  run_sync_cycle
  origin show main:company/z.md | grep -q hi
}

@test "the write probe asks git for its untranslated messages, whatever language this Mac speaks" {
  local real; real=$(command -v git)
  mkdir -p "$BRAIN_ROOT/shim"
  printf '#!/bin/bash\ncase " $* " in *" --dry-run "*) echo "${LC_ALL:-unset}" >> "%s/probe-locale";; esac\nexec "%s" "$@"\n' "$BRAIN_ROOT" "$real" > "$BRAIN_ROOT/shim/git"
  chmod +x "$BRAIN_ROOT/shim/git"
  PATH="$BRAIN_ROOT/shim:$PATH" LC_ALL=it_IT.UTF-8 run_sync_cycle
  [ -s "$BRAIN_ROOT/probe-locale" ]
  ! grep -qv '^C$' "$BRAIN_ROOT/probe-locale" || false
}

@test "a probe that cannot tell keeps the last mode instead of resetting a writable Mac" {
  echo "work" > "$MIRROR/company/w.md"
  printf '#!/bin/bash\necho "ssh: connect to host github.com port 22: Operation timed out" >&2\nexit 255\n' > "$BRAIN_ROOT/rp-unknown.sh"
  chmod +x "$BRAIN_ROOT/rp-unknown.sh"
  git -C "$MIRROR" config remote.origin.receivepack "$BRAIN_ROOT/rp-unknown.sh"
  run run_sync_cycle
  [ -e "$STATE/brain-writable" ]
  [ -f "$MIRROR/company/w.md" ]
  grep -q "could not tell whether this Mac may write" "$LOG"
}

# A colleague's push to the Brain, from a throwaway clone.
colleague_push() {
  local o; o=$(mktemp -d); git clone -q "$BRAIN_ROOT/origin-mirror.git" "$o"
  mkdir -p "$o/$(dirname "$1")"; echo "$2" > "$o/$1"
  git -C "$o" add -A; git_commit "$o" colleague; git -C "$o" push -q origin main; rm -rf "$o"
}
nothing_kept() { [ ! -d "$STATE/$1" ] || [ -z "$(ls -A "$STATE/$1")" ]; }

@test "a read-only Mac with no work of its own does not call a colleague's upstream change its unsent work" {
  make_brain_readonly; run_sync_cycle
  colleague_push sub/file.txt "alice edit"      # an existing page changes upstream: the old copy here now differs from origin
  run_sync_cycle
  [ "$(cat "$MIRROR/sub/file.txt")" = "alice edit" ]
  nothing_kept brain-unsent
  [ ! -f "$MARK" ]
}

@test "a read-only Mac with work of its own keeps only that work, not what a colleague changed meanwhile" {
  make_brain_readonly; run_sync_cycle
  chmod -R u+w "$MIRROR"; echo "mine" > "$MIRROR/company/brand-rules.md"
  colleague_push company/colleague.md "from alice"
  colleague_push sub/file.txt "alice edit"
  run_sync_cycle
  local d; d=$(ls -d "$STATE"/brain-unsent/*)
  [ "$(cat "$d/files/company/brand-rules.md")" = mine ]
  [ ! -e "$d/files/company/colleague.md" ]
  [ ! -e "$d/files/sub/file.txt" ]
  ! grep -q "alice" "$d/changes.patch" || false
}

@test "a protected page changed on a read-only Mac is kept aside before it is put back, and the person is told" {
  make_brain_readonly; run_sync_cycle
  edit_protected CLAUDE.md "my rule"
  chmod u+w "$MIRROR/method"; echo "my method" > "$MIRROR/method/new.md"
  chmod u+w "$MIRROR/company"; rm -f "$MIRROR/company/stock-status.md"
  run_sync_cycle
  local kept; kept=$(ls -d "$STATE"/protected-edits/*)
  [ "$(cat "$kept/CLAUDE.md")" = "my rule" ]
  [ "$(cat "$kept/method/new.md")" = "my method" ]
  [ "$(cat "$MIRROR/CLAUDE.md")" = "$(origin show main:CLAUDE.md)" ]
  [ ! -e "$MIRROR/method/new.md" ]
  [ -e "$MIRROR/company/stock-status.md" ]
  grep -q "locked page" "$MARK"
}

# --- a copy that cannot be made must stop the reset, never follow it ---------------------------------

@test "read-only: when the unsent work cannot be copied, nothing is reset or deleted and the person is told" {
  make_brain_readonly; run_sync_cycle
  chmod -R u+w "$MIRROR"; echo "mine" > "$MIRROR/company/brand-rules.md"; echo "new" > "$MIRROR/company/fresh.md"
  colleague_push company/colleague.md "from alice"
  echo "in the way" > "$STATE/brain-unsent"                  # the folder it must write into cannot be made
  run run_sync_cycle
  [ "$status" -ne 0 ]
  [ "$(cat "$MIRROR/company/brand-rules.md")" = mine ]
  [ "$(cat "$MIRROR/company/fresh.md")" = new ]
  [ "$(git -C "$MIRROR" rev-parse HEAD)" != "$(origin rev-parse main)" ]        # no reset either
  grep -q "could not keep" "$LOG"
  grep -q "Nothing in the Serlinolab_Brain folder was changed" "$MARK"
  ! grep -qiwE 'git|commit|rebase|reset|clean' "$MARK" || false
  rm -f "$STATE/brain-unsent"; run_sync_cycle                                   # the cause goes away: it all happens
  [ "$(git -C "$MIRROR" rev-parse HEAD)" = "$(origin rev-parse main)" ]
  [ "$(cat "$STATE"/brain-unsent/*/files/company/brand-rules.md)" = mine ]
  ! grep -q "Nothing in the Serlinolab_Brain folder was changed" "$MARK" 2>/dev/null || false
}

@test "read-only: when no temporary file can be made, nothing is reset either" {
  make_brain_readonly; run_sync_cycle
  chmod -R u+w "$MIRROR"; echo "mine" > "$MIRROR/company/brand-rules.md"
  colleague_push company/colleague.md "from alice"
  TMPDIR="$BRAIN_ROOT/no-such-tmp" run run_sync_cycle
  [ "$(cat "$MIRROR/company/brand-rules.md")" = mine ]
  [ "$(git -C "$MIRROR" rev-parse HEAD)" != "$(origin rev-parse main)" ]
  grep -q "could not keep" "$LOG"
}

@test "writable: when a protected edit cannot be copied it stays exactly as the person left it, and nothing is shared until it can be" {
  edit_protected CLAUDE.md "my rule"
  echo "in the way" > "$STATE/protected-edits"
  echo "a real note" >> "$MIRROR/company/brand-rules.md"
  run run_sync_cycle
  [ "$status" -ne 0 ]
  [ "$(cat "$MIRROR/CLAUDE.md")" = "my rule" ]                                  # not restored
  ! origin show main:CLAUDE.md | grep -q "my rule" || false                      # not shared
  ! origin show main:company/brand-rules.md | grep -q "a real note" || false      # nothing goes out while a copy is missing (K1)
  grep -q "Nothing in the Serlinolab_Brain folder was changed" "$MARK"
  rm -f "$STATE/protected-edits"; run_sync_cycle                                 # recovers once the cause is gone
  origin show main:company/brand-rules.md | grep -q "a real note"
  [ "$(cat "$STATE"/protected-edits/*/CLAUDE.md)" = "my rule" ]
  [ "$(cat "$MIRROR/CLAUDE.md")" = "$(origin show main:CLAUDE.md)" ]
}

# --- every team/ safeguard, on the Brain -------------------------------------------------------------

@test "a file that looks like a secret is kept out of the Brain and the person is told" {
  printf 'key=AKIAABCDEFGHIJKLMNOP\n' > "$MIRROR/company/oops.md"
  echo fine > "$MIRROR/company/fine.md"
  run_sync_cycle
  ! origin ls-tree -r --name-only main | grep -q oops.md || false
  origin show main:company/fine.md >/dev/null
  [ -f "$MIRROR/company/oops.md" ]
  grep -q "password or access key" "$MARK"
  grep -q "Serlinolab_Brain" "$MARK"
}

@test "a file over 10 MB is left out of the Brain and the person is told" {
  dd if=/dev/zero of="$MIRROR/company/huge.bin" bs=1048576 count=11 2>/dev/null
  echo fine > "$MIRROR/company/fine.md"
  run_sync_cycle
  ! origin ls-tree -r --name-only main | grep -q huge.bin || false
  ! origin log --all --name-only --format= | grep -q huge.bin || false   # in no commit of any ref, not just main's tip
  ! git -C "$MIRROR" log --all --name-only --format= | grep -q huge.bin || false
  origin show main:company/fine.md >/dev/null
  grep -q "too big to share" "$MARK"
  grep -q "huge.bin" "$MARK"
}

@test "a big file a colleague already put in the Brain does not raise a false alarm, nor hide real notices" {
  local o; o=$(mktemp -d); git clone -q "$BRAIN_ROOT/origin-mirror.git" "$o"
  dd if=/dev/zero of="$o/company/colleague-huge.bin" bs=1048576 count=11 2>/dev/null
  git -C "$o" add -A; git_commit "$o" "colleague big file"; git -C "$o" push -q origin main; rm -rf "$o"
  printf 'key=AKIAABCDEFGHIJKLMNOP\n' > "$MIRROR/company/oops.md"
  run_sync_cycle; run_sync_cycle
  [ -f "$MIRROR/company/colleague-huge.bin" ]
  [ ! -s "$STATE/brain_oversized_rejects" ]
  ! grep -q "too big" "$MARK" || false
  grep -q "password or access key" "$MARK"                 # the notice that was hidden before
}

@test "OS junk is never committed from the Brain, and junk already in an unpushed commit is dropped" {
  mkdir -p "$MIRROR/company/.AppleDouble"; echo j > "$MIRROR/company/.DS_Store"; echo j > "$MIRROR/company/.AppleDouble/x"
  echo real > "$MIRROR/company/real.md"
  git -C "$MIRROR" add -f company/.DS_Store; git_commit "$MIRROR" "junk by an older engine"
  run_sync_cycle
  origin show main:company/real.md >/dev/null
  ! origin log --all --name-only | grep -q 'DS_Store\|AppleDouble' || false
  [ -f "$MIRROR/company/.DS_Store" ]                 # still on disk, only out of git
}

@test "two Macs editing the same page at once keep both versions, with no alarm" {
  setup_second_brain_mac
  echo "line from alice" >> "$MIRROR/company/brand-rules.md"
  echo "line from karl" >> "$ROOT2/Serlinolab_Brain/company/brand-rules.md"
  run_sync_cycle
  run_second_mac_sync_cycle
  run_sync_cycle
  for f in "$MIRROR/company/brand-rules.md" "$ROOT2/Serlinolab_Brain/company/brand-rules.md"; do
    grep -q "line from alice" "$f"; grep -q "line from karl" "$f"
  done
  origin show main:company/brand-rules.md | grep -q "line from karl"
  [ ! -f "$ROOT2/SOMETHING NEEDS YOUR ATTENTION.txt" ]
  grep -q "Serlinolab_Brain/company/brand-rules.md" "$STATE2/team_changes.log"
}

@test "a binary page edited on two Macs is parked with both copies, and the person is told" {
  setup_second_brain_mac
  { printf '\x00'; head -c 64 /dev/urandom; } > "$MIRROR/company/pic.bin"
  { printf '\x00'; head -c 64 /dev/urandom; } > "$ROOT2/Serlinolab_Brain/company/pic.bin"
  cp "$ROOT2/Serlinolab_Brain/company/pic.bin" "$BRAIN_ROOT/karl.bin"
  run_sync_cycle
  run run_second_mac_sync_cycle
  [ "$status" -ne 0 ]
  cmp -s "$ROOT2/Serlinolab_Brain/company/pic.bin" "$BRAIN_ROOT/karl.bin"           # hers stays on disk
  local saved; saved=$(find "$STATE2/brain-conflicts" -name pic.bin | head -1)
  [ -n "$saved" ]
  [ "$(cat "$STATE2/brain_conflict_attempts")" = 1 ]
  grep -q "changed by you and by a colleague" "$ROOT2/SOMETHING NEEDS YOUR ATTENTION.txt"
  grep -q "Serlinolab_Brain" "$ROOT2/SOMETHING NEEDS YOUR ATTENTION.txt"
  [ ! -e "$STATE2/conflict_attempts" ]                                              # team/'s own latch is separate
}

@test "an autostash that cannot be reapplied is reported and never pushed" {
  local other; other=$(mktemp -d); git clone -q "$BRAIN_ROOT/origin-mirror.git" "$other"
  echo "colleague" > "$other/sub/file.txt"; git -C "$other" add -A; git_commit "$other" colleague; git -C "$other" push -q origin main
  rm -rf "$other"
  echo "dirty local edit" > "$MIRROR/sub/file.txt"      # tracked, dirty, uncommitted - what autostash stashes
  run bash -c "source '$REPO_ROOT/lib/common.sh'; source '$REPO_ROOT/lib/secretscan.sh'; \
    source '$REPO_ROOT/lib/team_layout.sh'; source '$REPO_ROOT/lib/complete_setup.sh'; \
    source '$REPO_ROOT/lib/sync.sh'; sync_mirror; rc=\$?; update_attention_marker; exit \$rc"
  [ "$status" -ne 0 ]
  [ -f "$STATE/brain_autostash_conflict" ]
  grep -q "could not be" "$MARK"
  grep -q "Serlinolab_Brain" "$MARK"
  git -C "$MIRROR" stash list | grep -q .
  ! origin show main:sub/file.txt | grep -q "<<<<<<<" || false
}

@test "a Brain whose origin was swapped is neither committed to nor pushed from" {
  git -C "$MIRROR" remote set-url origin "$BRAIN_ROOT/some-other-repo.git"
  echo "my note" > "$MIRROR/company/mine.md"
  run run_sync_cycle
  git -C "$MIRROR" status --porcelain | grep -qF "?? company/mine.md"
  grep -q "mirror origin does not match the expected remote" "$LOG"
  grep -qi "company folder" "$MARK"
}

@test "with no network the Brain edit is still committed locally, and goes out when it returns" {
  echo "written offline" > "$MIRROR/company/offline.md"
  edit_protected CLAUDE.md "offline rule"
  mv "$BRAIN_ROOT/origin-mirror.git" "$BRAIN_ROOT/origin-mirror.git.moved"
  ONLINE_CHECK_REMOTE="$BRAIN_ROOT/no-such-remote" run_sync_cycle
  [ "$(git -C "$MIRROR" rev-list --count origin/main..HEAD)" = 1 ]
  [ "$(git -C "$MIRROR" show --name-only --format= HEAD)" = "company/offline.md" ]   # the protected edit did not go in
  [ "$(cat "$STATE"/protected-edits/*/CLAUDE.md)" = "offline rule" ]
  run bash -c "echo x >> '$MIRROR/CLAUDE.md'" 2>/dev/null; [ "$status" -ne 0 ]      # and the lock is back, offline too
  mv "$BRAIN_ROOT/origin-mirror.git.moved" "$BRAIN_ROOT/origin-mirror.git"
  run_sync_cycle
  origin show main:company/offline.md | grep -q offline
}

@test "no network call precedes commit_brain in the real entry point" {
  local at head
  at=$(grep -n '^commit_brain ' "$REPO_ROOT/sync.sh" | cut -d: -f1)
  [ -n "$at" ]
  head=$(sed -n "1,$((at - 1))p" "$REPO_ROOT/sync.sh" | grep -v '^[[:space:]]*#')
  run grep -nE '\bonline\b|fetch|push|pull|clone|ls-remote|curl' <<<"$head"
  [ "$status" -ne 0 ]
}

# --- heartbeat ---------------------------------------------------------------------------------

@test "a Brain push that fails shows in the heartbeat the way a team failure does" {
  make_fake_team_repo
  run_sync_cycle
  local branch="status/testperson-$(cat "$STATE/machine-id")"
  printf '#!/bin/bash\necho "remote: some other failure" >&2\nexit 1\n' > "$BRAIN_ROOT/origin-mirror.git/hooks/pre-receive"
  chmod +x "$BRAIN_ROOT/origin-mirror.git/hooks/pre-receive"
  echo "an open page" > "$MIRROR/company/open.md"
  run run_sync_cycle
  [ "$status" -ne 0 ]
  git -C "$BRAIN_ROOT/origin-team.git" show "$branch:status.txt" | grep -q "result: problem - cycle exit 1"
  grep -q "push failed" "$LOG"
}

# --- MAX-1790 round 2 --------------------------------------------------------------------------------

# every file's content and the HEAD, so "nothing was changed" is measured, not claimed
folder_state() { (cd "$MIRROR" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 shasum; find . -path ./.git -prune -o -type l -exec readlink {} \;; git rev-parse HEAD; git stash list; git status --porcelain); }
# a bin dir whose `git` fails for one subcommand and is the real git otherwise
git_failing_on() {
  local real; real=$(command -v git); mkdir -p "$BRAIN_ROOT/failbin"
  printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = "%s" ] && exit 1; done\nexec %s "$@"\n' "$1" "$real" > "$BRAIN_ROOT/failbin/git"
  chmod +x "$BRAIN_ROOT/failbin/git"
}

@test "K1 writable: when a protected edit cannot be copied, the Brain is not synced at all that cycle and the notice is true" {
  edit_protected CLAUDE.md "my rule"
  echo "in the way" > "$STATE/protected-edits"
  colleague_push CLAUDE.md "the colleague's rules"
  echo "a real note" >> "$MIRROR/company/brand-rules.md"
  local before after; before=$(folder_state)
  run run_sync_cycle
  [ "$status" -ne 0 ]
  after=$(folder_state)
  [ "$before" = "$after" ]                                                      # not one file, commit or stash changed
  grep -q "Nothing in the Serlinolab_Brain folder was changed" "$MARK"
  ! grep -q '^<<<<<<<\|^>>>>>>>' "$MIRROR/CLAUDE.md" || false
  ! origin show main:company/brand-rules.md | grep -q "a real note" || false      # and nothing was pushed
  rm -f "$STATE/protected-edits"; run_sync_cycle                                 # the cause goes away: all of it happens
  [ "$(cat "$STATE"/protected-edits/*/CLAUDE.md)" = "my rule" ]
  [ "$(cat "$MIRROR/CLAUDE.md")" = "the colleague's rules" ]
  origin show main:company/brand-rules.md | grep -q "a real note"
}

@test "K1 writable: when one of two protected copies fails, neither is put back" {
  edit_protected CLAUDE.md "my rule"; edit_protected AGENTS.md "my agents"
  chmod 000 "$MIRROR/AGENTS.md"
  run run_sync_cycle
  chmod 644 "$MIRROR/AGENTS.md"
  [ "$status" -ne 0 ]
  [ "$(cat "$MIRROR/CLAUDE.md")" = "my rule" ]                                   # the one that could have been copied stays too
  [ "$(cat "$MIRROR/AGENTS.md")" = "my agents" ]
  grep -q "Nothing in the Serlinolab_Brain folder was changed" "$MARK"
}

@test "K2 a protected change someone staged is never committed: staged and then reverted on disk" {
  local before; before=$(origin rev-parse main)
  edit_protected CLAUDE.md "staged rule"; git -C "$MIRROR" add CLAUDE.md
  edit_protected CLAUDE.md "$(origin show main:CLAUDE.md)"                       # the file on disk is back, the staged copy is not
  echo "a real note" >> "$MIRROR/company/brand-rules.md"
  run_sync_cycle
  origin show main:company/brand-rules.md | grep -q "a real note"                # a commit did happen
  [ "$(origin show main:CLAUDE.md)" = "$(origin show "$before:CLAUDE.md")" ]
  ! origin diff --name-only "$before" main | grep -q CLAUDE.md || false
  ! git -C "$MIRROR" diff --name-only "$before" HEAD | grep -q CLAUDE.md || false
}

@test "K2 a protected change someone staged is never committed: not after a failed copy, not once the copy works again" {
  local before; before=$(origin rev-parse main)
  edit_protected CLAUDE.md "staged rule"; git -C "$MIRROR" add CLAUDE.md
  echo "in the way" > "$STATE/protected-edits"
  echo "a real note" >> "$MIRROR/company/brand-rules.md"
  run run_sync_cycle
  [ "$status" -ne 0 ]
  [ "$(git -C "$MIRROR" rev-parse HEAD)" = "$before" ]                           # no commit at all while the copy fails
  rm -f "$STATE/protected-edits"; run_sync_cycle
  [ "$(cat "$STATE"/protected-edits/*/CLAUDE.md)" = "staged rule" ]
  origin show main:company/brand-rules.md | grep -q "a real note"
  ! origin diff --name-only "$before" main | grep -q CLAUDE.md || false
  ! git -C "$MIRROR" diff --name-only "$before" HEAD | grep -q CLAUDE.md || false
}

@test "K3 read-only: an ignored local file a colleague adds upstream is kept before it is overwritten" {
  make_brain_readonly; run_sync_cycle
  chmod -R u+w "$MIRROR"; printf '*.local.md\n' > "$BRAIN_ROOT/ignore"; git -C "$MIRROR" config core.excludesFile "$BRAIN_ROOT/ignore"
  echo "mine" > "$MIRROR/company/plans.local.md"
  git -C "$MIRROR" check-ignore -q company/plans.local.md                       # ignored, as a global ignore would have it
  local o; o=$(mktemp -d); git clone -q "$BRAIN_ROOT/origin-mirror.git" "$o"
  echo "theirs" > "$o/company/plans.local.md"; git -C "$o" add -f -A; git_commit "$o" colleague; git -C "$o" push -q origin main; rm -rf "$o"
  run_sync_cycle
  [ "$(cat "$MIRROR/company/plans.local.md")" = theirs ]
  grep -rqx mine "$STATE" --include=plans.local.md
}

@test "K3 writable: an ignored local file a colleague adds upstream is kept before it is overwritten" {
  printf '*.local.md\n' > "$BRAIN_ROOT/ignore"; git -C "$MIRROR" config core.excludesFile "$BRAIN_ROOT/ignore"
  echo "mine" > "$MIRROR/company/plans.local.md"
  git -C "$MIRROR" check-ignore -q company/plans.local.md                       # ignored, as a global ignore would have it
  local o; o=$(mktemp -d); git clone -q "$BRAIN_ROOT/origin-mirror.git" "$o"
  echo "theirs" > "$o/company/plans.local.md"; git -C "$o" add -f -A; git_commit "$o" colleague; git -C "$o" push -q origin main; rm -rf "$o"
  run_sync_cycle
  [ "$(cat "$MIRROR/company/plans.local.md")" = theirs ]
  grep -rqx mine "$STATE" --include=plans.local.md
}

@test "K3 an ignored local file nobody else has, or the same text, is left alone and raises no notice" {
  printf '*.local.md\n' > "$BRAIN_ROOT/ignore"; git -C "$MIRROR" config core.excludesFile "$BRAIN_ROOT/ignore"
  echo "mine" > "$MIRROR/company/plans.local.md"
  run_sync_cycle
  [ "$(cat "$MIRROR/company/plans.local.md")" = mine ]
  [ -z "$(find "$STATE" -name plans.local.md -not -path "$MIRROR/*")" ]
}

@test "S2 a refusal whose protected text could not be copied is retried next cycle, and the note still gets out" {
  install_ruleset_hook
  chmod u+w "$MIRROR/CLAUDE.md"; echo hacked >> "$MIRROR/CLAUDE.md"; echo ok > "$MIRROR/company/new-ok.md"
  git -C "$MIRROR" add -A; git_commit "$MIRROR" "made by hand: protected and open together"
  echo "in the way" > "$STATE/protected-edits"
  run run_sync_cycle
  [ "$status" -ne 0 ]
  ! origin show main:company/new-ok.md >/dev/null 2>&1 || false
  rm -f "$STATE/protected-edits"; run_sync_cycle
  origin show main:company/new-ok.md | grep -q ok
  ! origin show main:CLAUDE.md | grep -q hacked || false
  grep -rq hacked "$STATE/protected-edits"
}

@test "S3 a big file already in team/ raises no alarm; one that was refused still does" {
  make_fake_team_repo
  local o; o=$(mktemp -d); git clone -q "$BRAIN_ROOT/origin-team.git" "$o"
  dd if=/dev/zero of="$o/colleague-huge.bin" bs=1048576 count=11 2>/dev/null
  git -C "$o" add -A; git_commit "$o" "colleague big file"; git -C "$o" push -q origin main; rm -rf "$o"
  run_sync_cycle; run_sync_cycle
  [ -f "$TEAM/colleague-huge.bin" ]
  ! grep -q "too big" "$MARK" 2>/dev/null || false
  dd if=/dev/zero of="$TEAM/mine-huge.bin" bs=1048576 count=11 2>/dev/null
  run_sync_cycle
  grep -q "mine-huge.bin" "$MARK"
}

@test "S4 a stale too-big notice does not hide the unsent notice when the key goes back to read-only" {
  dd if=/dev/zero of="$MIRROR/company/huge.bin" bs=1048576 count=11 2>/dev/null
  run_sync_cycle
  grep -q "too big" "$MARK"
  make_brain_readonly
  echo "mine" >> "$MIRROR/company/brand-rules.md"
  run_sync_cycle; run_sync_cycle
  grep -q "can no longer change" "$MARK"
  ! grep -q "too big" "$MARK" || false
  BRAIN_NOTICE_MINUTES=0 run_sync_cycle                                          # the unsent notice has expired: the size one must not come back
  ! grep -q "too big" "$MARK" 2>/dev/null || false
}

@test "S4 a size notice never hides a notice about kept or unsent text" {
  dd if=/dev/zero of="$MIRROR/company/huge.bin" bs=1048576 count=11 2>/dev/null
  edit_protected CLAUDE.md "my rule"
  run_sync_cycle
  grep -q "locked page" "$MARK"
}

@test "S5 read-only: when the patch of unsent work cannot be made, nothing is reset" {
  make_brain_readonly; run_sync_cycle
  chmod -R u+w "$MIRROR"; echo "mine" > "$MIRROR/company/brand-rules.md"
  colleague_push company/colleague.md "from alice"
  git_failing_on --binary
  PATH="$BRAIN_ROOT/failbin:$PATH" run run_sync_cycle
  [ "$status" -ne 0 ]
  [ "$(cat "$MIRROR/company/brand-rules.md")" = mine ]
  [ "$(git -C "$MIRROR" rev-parse HEAD)" != "$(origin rev-parse main)" ]
  grep -q "Nothing in the Serlinolab_Brain folder was changed" "$MARK"
}

@test "S5 a refusal whose protected text cannot be read back changes none of the commits" {
  install_ruleset_hook
  chmod u+w "$MIRROR/CLAUDE.md"; echo hacked >> "$MIRROR/CLAUDE.md"; echo ok > "$MIRROR/company/new-ok.md"
  git -C "$MIRROR" add -A; git_commit "$MIRROR" "made by hand: protected and open together"
  local head; head=$(git -C "$MIRROR" rev-parse HEAD)
  git_failing_on show
  PATH="$BRAIN_ROOT/failbin:$PATH" run run_sync_cycle
  [ "$status" -ne 0 ]
  [ "$(git -C "$MIRROR" rev-parse HEAD)" = "$head" ]                             # not rebuilt without the text it could not save
  grep -q hacked "$MIRROR/CLAUDE.md"
}
