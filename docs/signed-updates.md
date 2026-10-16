# Signed engine updates

The self-contained launcher authenticates the fetched **commit object** before checkout,
selfcheck or sourcing. The commit signature header must be `-----BEGIN SSH SIGNATURE-----`;
PGP and X.509 verifiers are explicitly disabled. `git verify-commit` uses `gpg.format=ssh` and
`gpg.ssh.allowedSignersFile` at `~/Serlinolab/.state/update-trust/allowed_signers` (directory
0700, file 0600, owned by this user, outside every synced repository). Repository copies never authorize verification; Git replacement objects are disabled.
The threat is a main writer without Max's dedicated release key, not malware already running as this Mac user.

The trust file also records the last authenticated SHA. A candidate must equal or descend from
that SHA (`merge-base --is-ancestor`); dates and GitHub badges are not authority.
The high-water mark advances even if a signed release fails selfcheck. `engine-verified`
separately remembers the last working authenticated release: rejection leaves/rereads that
release, cleans the engine checkout, and continues syncing. Selfcheck failure may restore that
working release without lowering the high-water mark. Once trust is installed, corrupt trust fails closed; there is no unverified HEAD fallback.
Errors/enforcement reach the existing heartbeat; without a trusted fallback execution stops
and heartbeat becomes stale. A transient engine fetch failure is logged but does not change a
successful sync's heartbeat to `problem`.

During the one-time legacy transition only, if HEAD cannot bootstrap, the launcher fetches
`main` and tries the fetched commit against the embedded pin **before checkout**. A verified
candidate must pass selfcheck before trust and the working-release marker are installed.
If bootstrap still fails, an existing Mac continues its already installed code, publishes
`problem - self-update: bootstrap ...` with `signed updates: pending-transition`, and retries
next cycle. It does not check out an unverified fetched tip. A signed forward fix published
later therefore recovers the Mac automatically. This availability exception ends once the
external trust store exists; a fresh clone has no installed code to fall back to.

**Bootstrap:** `setup.sh` contains a literal SSH SHA256 key fingerprint (also embedded in the
launcher). It clones with `--no-checkout`, reads `config/allowed_signers` as an object, checks
its one-key list or two-key rotation bridge against that fingerprint, verifies the commit using
**only the pinned key**, then checks out/runs it. Bootstrap accepts only `ssh-ed25519` keys.
An old-key-pinned installer accepts a bridge signed by the old key, never merely a new-key
signature on a list containing the old public key.
Replace the placeholders before shipping. The installer itself
remains the initial trust root: a main writer can replace both verifier and pin. Distribute
a reviewed installer at an immutable commit URL; confirm its checksum independently.
The pin cannot authenticate the script delivering it.
Re-running setup uses existing external trust and cannot silently re-pin it.

**Custody and rotation:** Max holds a dedicated passphrase-protected SSH signing key, separate from
access/deploy keys **and Max's everyday commit-signing key**, with an encrypted offline backup.
This key signs **only reviewed release tips**. Never enable global `commit.gpgsign` for it;
select it explicitly for each release command. Register its public key
as a GitHub **signing** key for attribution (GitHub registration does not authorize Macs).
Ship a signed descendant changing `config/allowed_signers` to old + new keys. Only after the
old key has authenticated that release and its selfcheck succeeds is the external list atomically
replaced. Wait for every Mac's heartbeat to confirm adoption before signing with the new key;
then ship a new-key-signed descendant removing the old key. Update bootstrap pins for new Macs
and the initial list to a single new key at that point. Offline Macs missing the bridge need
operator-assisted installation of the old-key-signed bridge before the new-key-only release.
For emergency revocation, stop publishing, disable compromised GitHub access, and deliver
replacement trust plus a reviewed signed recovery release out of band to each Mac. A compromised-key signature cannot authorize recovery; deleting a GitHub key does not revoke
the Mac's pin. Never erase ancestry state to
accept a force-push; recover by signing a forward fix or an explicitly audited local rebootstrap.

**App ZIP:** `app/SHA256` detects corruption; it is authoritative only because the commit
carrying both checksum and ZIP has an allowed signature. Bundle validation is an additional check.

**Fleet rollout:**
1. Prepare the real key/list/pins and test locally. Make the release tip **T**, containing this
   enforcing launcher, installer, heartbeat and trust list, itself SSH-signed with the dedicated release key. A GitHub
   web/squash/merge signature by another key is insufficient: the actual `main` tip must verify.
2. Publish T as a descendant of current main during a controlled write window. The existing
   unauthenticated launcher necessarily checks out and runs T once, then `ensure_launcher_current`
   atomically installs T's launcher. This one transition run is NOT protected retrospectively.
3. On the next cycle the new launcher verifies installed T against its embedded pin, creates
   external trust, and begins enforcement. If the legacy updater landed on an unsigned web merge,
   bootstrap instead fetches/retries as described above while the installed code keeps syncing.
   Keep main at T until reachable Macs report `signed updates: enforced` and `signed anchor: <T>`. An interrupted
   checkout/refresh retries the normal selfcheck/cycle and completes the transition.
4. Thereafter publish only signed descendants, preserving bootstrap code/list for late Macs.
   A Mac offline throughout T can land directly on a later signed descendant via its old launcher,
   then bootstrap/enforce on its next cycle; it need not observe exactly T. Such a Mac remains
   exposed until that transition. Inventory offline Macs; do not claim fleet enforcement early.

## Release procedure (engine and app payloads)

Never use the GitHub merge button for this repository: web merge/squash commits use GitHub's
key, which the Macs do not accept. Review the PR and its final diff first. From a clean local
brain-sync checkout, merge locally and sign the resulting release tip with the dedicated key:

```sh
git fetch && git checkout main && git merge --ff-only origin/main
# Replace <reviewed-branch> with the reviewed local branch or fetched origin/<branch>.
git -c gpg.format=ssh -c user.signingkey="$HOME/.ssh/brain_sync_release_ed25519" \
  merge --no-ff -S <reviewed-branch>
git -c gpg.format=ssh -c gpg.program=false -c gpg.x509.program=false \
  -c gpg.ssh.program=ssh-keygen -c gpg.ssh.allowedSignersFile=config/allowed_signers \
  -c gpg.ssh.revocationFile=/dev/null verify-commit HEAD
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.defaultBranch GIT_CONFIG_VALUE_0=main bats tests/
git push origin main
```

The ruleset allows fast-forward pushes: this local merge descends from `origin/main` and the
push is a normal fast-forward ref update, even though the merge uses `--no-ff`. If main moves,
fetch and review the new changes, create and sign the resulting release tip again, verify and
retest; never force-push. If the reviewed PR was already web-merged, first fast-forward locally,
review that exact tip, then create an explicit signed release tip before verification/testing:

```sh
git -c gpg.format=ssh -c user.signingkey="$HOME/.ssh/brain_sync_release_ed25519" \
  commit --allow-empty -S -m "Release reviewed main"
```

For brain-app, `scripts/publish-to-engine.sh ../brain-sync` prepares the three `app/` payload
files. Open/review their engine PR, then follow the **same local signed merge procedure above**;
the publishing script and GitHub merge button do not replace signing the engine release tip.
For installer distribution, Max publishes the immutable release commit ID and the SHA256 of
that commit's `setup.sh` independently; use the checksum-checked command in README.md.

## Follow-up outside this change

`brain-app/Vendor/brain-sync/setup.sh` still pulls and sources unsigned `main` during DMG
onboarding. After this lands, re-vendor the reviewed installer, remove that unsigned onboarding
path and build/distribute a new DMG. Until then, onboard with the immutable checksum-checked
installer; an existing DMG is not evidence of signed onboarding.
