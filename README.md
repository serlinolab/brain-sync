# Serlino Brain — Mac sync

## Setup (one step)

Paste this into Terminal and press return:

```
curl -fsSL https://raw.githubusercontent.com/serlinolab/brain-sync/main/setup.sh | bash
```

It asks for your name, then does everything it can on its own. At the end
it prints one line starting with `SERLINO-BRAIN-SETUP` — copy that whole
line and send it to Max. That's the only thing you ever need to send him.

Send Max the line starting SERLINO-BRAIN-SETUP. That's all — your folders
appear on their own within a few minutes of his approval.

## What you'll see

A folder called `Serlino` in your home folder, with:

- **serlinolab/** — the Serlino brain, kept current on its own. Open the
  Code tab here to work — this is where its rules apply.
- **team/** — notes shared with the whole team. Save something here and
  everyone else sees it within a few minutes. What they save, you see too.
- **personal/** — yours alone, private to this Mac, with three folders inside
  to get you started (`brands`, `ideas`, `finds`).
- **what-changed.md** — a running list of recent changes in the Serlino brain.

You never type a command or approve anything after setup.

## What leaves your Mac, and what never does

Only `team/` leaves this Mac, and only to the team's own shared space —
never public, never anywhere else. Everything in `personal/` never leaves
this Mac, full stop. That's a fact about how this is built, not a setting
you could turn off.

Because `personal/` never leaves your Mac, it's also never backed up by
this tool. Back it up yourself (Time Machine, iCloud Drive, whatever you
use) if you'd want it back after your Mac is lost, stolen, or wiped.

## If "SOMETHING NEEDS YOUR ATTENTION.txt" appears

Open it and read it — it explains what's going on in plain language. Your work is never lost when this
appears, and it stays safely on your Mac either way. Send Max a message and it'll get sorted out.

## Limits worth knowing

- Setup needs Terminal once; you won't see it again unless something
  needs fixing.
- If this Mac has never been online since setup, the Serlino brain and the
  team folder may not have arrived yet — they land on first connect.

## For Max

Provisioning a new person's Mac, and revoking access for one that's lost or
returned, are covered in [`docs/runbook.md`](./docs/runbook.md).
