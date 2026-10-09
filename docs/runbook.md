# Runbook (for Max)

## Provisioning a new person or Mac

**Which way to onboard (2026-10-03):** the `curl | bash` line below. The SerlinoLab Brain
menu-bar app then arrives on its own within a few minutes (the engine installs it), so there is
nothing else to send. The DMG on Slack (brain-app `scripts/build-dmg.sh`) saves the one Terminal
paste (its wizard runs the same setup.sh) but adds an "Open Anyway" step in Privacy & Security
that needs an admin user: use it only for someone who won't use Terminal. Once the app is
notarized (MAX-1638) the DMG becomes the simpler way. The app needs macOS 14; on an older Mac the
engine skips it and keeps building the old Desktop launcher.
Check the result with `./fleet-status.sh`.

0. Before the person sets up, create their MediaBuy user in MediaBuy admin. They sign in to
   the MediaBuy connector with it (README, "Connect MediaBuy"); setup cannot do this step,
   because the sign-in must be their own.
1. The creator runs `setup.sh` on their Mac (see README.md). It ends by printing one line
   starting with `SERLINO-BRAIN-SETUP` and asks them to send it to you.
2. Paste that whole line as the argument to `provision.sh`, from a Mac with the `gh` CLI
   signed in to an account that can administer the `serlinolab` org:

   ```
   ./provision.sh "SERLINO-BRAIN-SETUP person=alice machine=alices-mac mirror_key=ssh-ed25519 AAAA... brain-mirror-alices-mac team_key=ssh-ed25519 AAAA... brain-team-alice"
   ```

   Add `--dry-run` first if you want to see what it would do without changing anything.
3. `provision.sh` creates `serlinolab/brain-team` (private) the first time it's ever run, and
   registers two GitHub deploy keys for that person+Mac, both read-write: one on
   `Serlinolab-Brain` (since MAX-1790; it used to be read-only - see "Editing the Brain directly")
   and one on `brain-team`.
4. Re-running provision.sh with the same pasted line is always safe - it recognises the
   deploy keys are already registered and does nothing further. It never overwrites a key. The one
   change it ever makes to an existing key is upgrading a read-only `Serlinolab-Brain` key to
   write access (delete and re-register the same key); any other mismatch is refused.
5. That's it - nothing to tell the creator. Their Mac's own background sync job (already
   installed by their first and only `setup.sh` run) calls `complete_setup`
   (`lib/complete_setup.sh`) every cycle; once the key is registered, the very next cycle
   clones and configures whatever is still missing, on its own, no Terminal paste required.
   To check progress on their Mac: `tail ~/Serlinolab/.state/sync.log`, or look for
   `~/Serlinolab/.state/setup-complete` (present once both `team/` and `Serlinolab_Brain/` are done).
   If it is still pending after `SETUP_PENDING_ALERT_HOURS` (default 24, set as an environment
   variable for the sync job - see `lib/common.sh`), the creator's Mac raises
   "SOMETHING NEEDS YOUR ATTENTION.txt" on its own to prompt them to check in with you.

## Revoking access (a lost or returned Mac)

Deactivate the person's MediaBuy user (`is_active = false` in MediaBuy admin). That cuts the
MediaBuy website and every Claude surface using the connector immediately, on the next call.

Deleting a deploy key stops that Mac's *next* fetch or push. It does **not** reach back to
whatever is already sitting on that Mac's disk - a copy that was already synced stays there
until the disk is wiped or encrypted, or the laptop is returned. That is why every Mac should
have disk encryption (FileVault) turned on: it is what actually protects a lost or stolen Mac,
not the deploy key.

List the deploy keys on each repo:

```
gh api repos/serlinolab/brain-team/keys
gh api repos/serlinolab/Serlinolab-Brain/keys
```

Delete the one belonging to the Mac you're revoking (use its `id` from the listing above):

```
gh api -X DELETE repos/serlinolab/brain-team/keys/<id>
gh api -X DELETE repos/serlinolab/Serlinolab-Brain/keys/<id>
```

## Editing the Brain directly (MAX-1790)

Everyone edits `~/Serlinolab/Serlinolab_Brain` directly. A save to any **unprotected** file is
committed under that person's sync identity and pushed to `serlinolab/Serlinolab-Brain` `main`
within one cycle (5 minutes), and reaches every other Mac the cycle after. **Protected** paths
stay read-only on disk and are never committed by the engine. Two layers keep them out:

1. **GitHub** (server side): the push ruleset `brain-protected-paths` refuses any push that touches a
   protected path (`GH013`, "push declined due to repository rule violations", "File path is restricted").
2. **The engine** (`lib/protected_paths.sh`, `lib/brain_write.sh`): protected paths are put back
   before anything is staged, and excluded from `git add` as a second layer.

### The protected paths

A repo-relative path is protected when **any** of these holds. **Matching ignores case**: Macs are
case-insensitive, so `notes/claude.md`, `notes/Agents.md` and `.CLAUDE/skills/x/SKILL.md` load as
instructions exactly like `CLAUDE.md`, `AGENTS.md` and `.claude/`. GitHub matches these paths
case-insensitively too (verified 2026-10-09 with a temporary write deploy key: all three were refused
with `GH013` "File path is restricted" while an unprotected file was accepted), so no case-variant
patterns are needed in the ruleset and the engine folds case for all four rules below, `method/` and
the seven export files included. Before this, `company/agents.md` was silently never shared; it is now
a protected path: kept in `protected-edits`, with the attention line.

- its name is `CLAUDE.md`, `CLAUDE.local.md` or `AGENTS.md`, at any depth;
- any directory component is `.claude` or `.agents` (the `.agents` symlink to `.claude/skills` is protected as a path itself);
- it is under top-level `method/`;
- it is one of the seven files the nightly export owns: `audits/latest-weekly.md`,
  `company/stock-status.md`, `competitors/README.md`, `voice-of-customer/corpus-profile.md`,
  `voice-of-customer/phrase-bank-it.md`, `voice-of-customer/phrase-bank-us.md`,
  `voice-of-customer/support-requests.md`.

**The list lives in one place in the engine, `lib/protected_paths.sh`, and it must mean the same as
the ruleset.** Change them together. An engine stricter than the ruleset is harmless; a ruleset stricter than
the engine only costs the refusal path described below on every such change. Edit the arrays in that
file, then run `tests/brain_two_way.bats`, which
checks the 18 refused and the open paths against both the predicate and the `git add` pathspecs.

### The ruleset, before and after (2026-10-07 and 2026-10-09)

Ruleset `brain-protected-paths` (id 24669694, target `push`, enforcement `active`). Bypass:
organisation admins and one integration (id 5001512), always. No branch conditions.

- **Before** (created 2026-10-07): `file_path_restriction` with 18 patterns: `CLAUDE.md`, `**/CLAUDE.md`,
  `CLAUDE.local.md`, `**/CLAUDE.local.md`, `AGENTS.md`, `**/AGENTS.md`, `.claude/**`, `**/.claude/**`,
  `.agents/**`, `**/.agents/**`, `method/**`, and the seven export files.
- **After** (updated 2026-10-09): the same 18 plus five: `.claude/**/*`, `**/.claude/**/*`,
  `.agents/**/*`, `**/.agents/**/*`, `method/**/*`. After the update a live probe on a throwaway branch refused all 18 protected paths
  (including new files under `.claude/`, `.agents/` and `method/` and at depth) and accepted the two
  unprotected ones (`company/brand-rules.md`, `running-notes/max-1790-probe.md`). The reason for the
  extra patterns was not written down.
- **Earlier still:** classic branch protection on `main` ("push restricted to maxmon64, pull request
  required") was removed on 2026-10-07 when the ruleset went in. Its JSON was never saved, so only
  that one-line description of it survives; do not expect to restore it from a file.

### Which Macs write: the per-cycle mode switch

Each cycle, after fetching, `sync_mirror` asks GitHub whether **this Mac's deploy key** may push
(`git push --dry-run`, which authenticates against receive-pack and sends nothing; a read-only key
fails with "marked as read only"). The answer picks the mode, so a Mac never needs to be told:

- **Read-only key** (every Mac until its key is upgraded, and again after a rollback): the old
  mirror, unchanged - fetch, `reset --hard`, `clean`, everything read-only. One addition: anything a
  person had written meanwhile (uncommitted edits, new files, unpushed commits) is copied first to
  `~/Serlinolab/.state/brain-unsent/<UTC time>/` (`files/` and `changes.patch`), and the attention
  file says so for 24 hours.
- **Writable key**: the same pipeline as `team/` (secret scan, 10 MB limit, OS junk, union merge of text
  conflicts, binary conflicts parked with both copies, autostash check, remote-match check, offline
  local commit), with its own state files (`brain_*`, `brain-conflicts/`) so a parked Brain never blocks
  `team/`. `.state/brain-writable` records the last answer; it is what lets the network-free local
  commit run before the probe. A probe that cannot tell (network trouble) keeps the previous mode.

A protected path that a person changed is copied to `~/Serlinolab/.state/protected-edits/<UTC time>/<path>`
and put back to what the Brain has (removed if it is new); the attention file says a locked page was
not shared and where the text is. If a push is still refused by the ruleset (commits made outside the
engine), the protected parts of the unpushed commits are moved to `protected-edits` the same way, the
commits are rebuilt without them and pushed once more; the refused state is recorded in
`.state/brain_push_parked` so the same commits are never pushed again until origin or the commits change.

### Upgrading a Mac's key to write access

`provision.sh` registers the Brain key with write access for every new Mac. Existing Macs hold a
read-only key; GitHub cannot flip `read_only` on a key, so the script deletes it and registers the
**same public key under the same title** again. Nothing is needed from the Mac:

```
./provision.sh --dry-run --upgrade-brain-key "brain-mirror alice alices-mac"   # prints what it would do
./provision.sh --upgrade-brain-key "brain-mirror alice alices-mac"
```

(the title is in `gh api repos/serlinolab/Serlinolab-Brain/keys`; or re-run the Mac's pasted
`SERLINO-BRAIN-SETUP` line, which upgrades the same way). It is idempotent. Re-registering a
`brain-team` key, or any other change of a key's `read_only`, is still refused. The Mac switches to
editable on its own the next cycle.

**If the upgrade fails halfway** (the delete worked, the new registration did not), the Mac has no key
on GitHub until it is registered again. The script saves the title and the **public** key to
`~/.serlino-brain-provision/` (`$BRAIN_PROVISION_STATE`) *before* deleting, and refuses to delete if
that cannot be written. After a failed write registration it retries once, then registers the old
read-only key again so the Mac keeps reading, and finally prints the exact `gh api` command. Re-running
`./provision.sh --upgrade-brain-key "<title>"` finds the saved key and finishes the upgrade; the title
alone is enough. The saved file is removed when the key is writable.

### Rollback

Re-register the Mac's Brain key as read-only (delete it and add it again with `read_only=true`, or
`gh api` by hand) and/or restore the previous engine. Each Mac falls back to mirror mode on its next
cycle; whatever it had written and not sent is in `~/Serlinolab/.state/brain-unsent/`. The ruleset can
stay: it only ever refuses protected paths.

### Revoking a key now cuts a writer, not only a reader

A Brain deploy key with write access can push. Deleting it (see "Revoking access") stops that Mac's
pushes as well as its fetches. Protected paths are the only thing a writable key cannot push, and only
because of the ruleset and the engine - a person with the key and a hand-made git client is held by
the ruleset alone.

## The Serlino Brain launcher

To rebuild it (`lib/brain_launcher.sh`), move `~/Applications/Serlino Brain.app` to the Trash; the next sync cycle builds a fresh one and a new Desktop shortcut - so while the sync job runs it cannot be removed for good, only the Desktop shortcut can (that one is never recreated while the app is there).
On a Mac set up before the launcher shipped, the first build comes from the background job, and macOS guards `~/Desktop`: that one shortcut write may raise a one-time "bash would like to access files in your Desktop folder" prompt, or fail silently (logged in `sync.log`, never retried). The app itself is always in `~/Applications`, which the README points people to.

Once the **SerlinoLab Brain** menu-bar app is in `/Applications` or `~/Applications` (MAX-1629), the engine stops building or rebuilding this launcher, and leaves an existing one where it is - the menu-bar app has its own Open Brain button and offers to remove the old launcher itself. Remove the menu-bar app and the next cycle builds the launcher again.

Every click alternates the Brain folder's spelling (without, then with, a trailing `/`; last choice in `~/Serlinolab/.launcher-last`) to dodge anthropics/claude-code#92210 - a link naming the folder already selected opens a scratch session instead. Side effect: Claude's sidebar may show the Brain as two groups. Remove the alternation (`brain_launcher_shell`) once #92210 is fixed.

## A parked conflict on a non-text file

A text file (a note, a Markdown page) never parks: two people editing the same note at the
same time is resolved automatically by unioning both versions' lines (`lib/sync.sh`,
`resolve_conflict_file` / `auto_rebase_onto_origin`). Only a genuinely binary file (an image, a
PDF, a video) can still park - `git diff --numstat` between the two conflicting versions
reports `-` for it (git's own binary detection, not a file-extension list).

When that happens the creator sees "SOMETHING NEEDS YOUR ATTENTION.txt" and both versions are
kept safely: the local one on disk in `team/`, the incoming one under
`~/Serlinolab/.state/conflicts/<timestamp>/`. To resolve it by hand:

1. `cd ~/Serlinolab/team` on the creator's Mac (or pull both files off it) and decide which
   version should win, or rename one so both can be kept side by side.
2. Put the winning file at its original path in `team/` and delete
   `~/Serlinolab/.state/conflict_attempts` so the next sync cycle treats it as resolved.
3. Wait for the next cycle (or run `bash sync.sh` from a checked-out copy of this engine) to
   confirm it pushes cleanly and the attention file clears itself.

A Mac that was already parked at the retry bound (`MAX_CONFLICT_ATTEMPTS`, `lib/common.sh`)
for a conflict that turns out to be TEXT heals itself on its very next cycle without any of the
above - the retry always re-attempts the rebase, and a text conflict always resolves.

## AC-3 manual check: the brand's rules load automatically

This cannot be verified from an automated test in this repo - it depends on the `claude` CLI
being signed in, which it is not in the environment these tests run in
(`tests/live_claude.bats` documents and skips this by default; set `BRAIN_LIVE_CLAUDE=1` to
run it on a Mac that is signed in).

To check by hand: open the Code tab on `~/Serlinolab/Serlinolab_Brain` on a set-up Mac and ask
the assistant to name the brand. It should answer using whatever is in
`~/Serlinolab/Serlinolab_Brain/CLAUDE.md`, without being told where to look.

## The SerlinoLab Brain menu-bar app

`lib/menubar_app.sh` installs, updates and keeps running the menu-bar app (MAX-1629, code in
`serlinolab/brain-app`) from `app/` in this repo. It reaches every Mac with the engine's own git
self-update, so no browser download is involved: no quarantine, no Gatekeeper prompt, and no trust
root beyond protected `main` here.

- **Ship a new version:** in brain-app, bump `VERSION`, then `scripts/publish-to-engine.sh ../brain-sync`
  and open a pull request here with the three changed files in `app/`. After merge, each Mac installs
  it within one or two cycles. The engine installs only when `app/VERSION` differs from the installed
  copy's version, and only after `app/SHA256`, the bundle signature and the bundle's own version all check out.
- **Where it goes:** a copy already in `/Applications` (dragged from the DMG) is updated in place;
  otherwise `~/Applications`. Never two copies.
- **Kept running, and back after every restart:** the sync job runs at login (`RunAtLoad`), and each
  cycle starts the app when it isn't running - unless the person quit it from its menu since the
  last boot (`~/Serlinolab/.state/app-quit`; a quit lasts until the next restart).
- **A brand-new Mac** still needs the app or `curl | bash` first, because the engine isn't there yet:
  send the DMG (brain-app `scripts/build-dmg.sh`) on Slack, not by email (Gmail blocks `.dmg`).
  That one copy must be unblocked once: System Settings → Privacy & Security → Open Anyway.
- **Stop distributing it:** delete `app/` here; installed copies stay, nothing new is installed.

