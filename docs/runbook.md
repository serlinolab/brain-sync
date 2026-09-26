# Runbook (for Max)

## Provisioning a new person or Mac

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
   registers two GitHub deploy keys for that person+Mac: a read-only one on
   `Serlinolab-Brain` and a read-write one on `brain-team`.
4. Re-running provision.sh with the same pasted line is always safe - it recognises the
   deploy keys are already registered and does nothing further. It never deletes or
   overwrites a key.
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

## The Serlino Brain launcher

To rebuild it (`lib/brain_launcher.sh`), move `~/Applications/Serlino Brain.app` to the Trash; the next sync cycle builds a fresh one and a new Desktop shortcut - so while the sync job runs it cannot be removed for good, only the Desktop shortcut can (that one is never recreated while the app is there).

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
