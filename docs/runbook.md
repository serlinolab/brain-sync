# Runbook (for Max)

## Provisioning a new person or Mac

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
5. Tell the creator to run `setup.sh` again. It will now finish cloning both repositories and
   start the background sync.

## Revoking access (a lost or returned Mac)

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

## AC-3 manual check: the brand's rules load automatically

This cannot be verified from an automated test in this repo - it depends on the `claude` CLI
being signed in, which it is not in the environment these tests run in
(`tests/live_claude.bats` documents and skips this by default; set `BRAIN_LIVE_CLAUDE=1` to
run it on a Mac that is signed in).

To check by hand: open the Code tab on `~/Serlino/team/serlinolab` on a set-up Mac and ask the
assistant to name the brand. It should answer using whatever is in
`~/Serlino/team/serlinolab/CLAUDE.md`, without being told where to look.
