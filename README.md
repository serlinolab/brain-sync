# Serlino Brain — Mac sync

## Setup (do this once)

Paste this into Terminal and press return:

```
curl -fsSL https://raw.githubusercontent.com/serlinolab/brain-sync/main/setup.sh | bash
```

It asks for your name, then finishes on its own. At the end it prints one
line starting with `SERLINO-BRAIN-SETUP` — copy that whole line and send it
to Max. That's the only thing you ever need to send him.

Running the line again on a Mac that's already set up does nothing, and tells you so.

## What you'll see

A folder called `Serlino` in your home folder, with:

- **serlinolab/** — the company's shared knowledge, kept current on its
  own. You can look, but you can't change anything in it - on purpose.
- **team/** — the same idea, for your team, filled in over time.
- **personal/shared/** — your notes, shared with the team. A save here
  reaches everyone else within a few minutes.
- **personal/** (outside `shared/`) — yours alone, never leaves your Mac.
- **what-changed.md** — a running list of recent company-folder changes.

Open all of this from the Code tab, same as always. You never type a
command or approve anything after setup.

## What leaves your Mac, and what never does

Only `personal/shared/` leaves this Mac, and only to your own private
notes space - never public, never to another creator. Everything else in
`personal/` never leaves this Mac, full stop. That's a fact about how
this is built, not a setting you could turn off.

Because that folder never leaves your Mac, it's also never backed up by
this tool. Back it up yourself (Time Machine, iCloud Drive, whatever you
use) if you'd want it back after your Mac is lost, stolen, or wiped.

## If "SOMETHING NEEDS YOUR ATTENTION.txt" appears

Open it and read it - it explains what's going on in plain language. Your work is never lost when this
appears, and it stays safely on your Mac either way. Send Max a message and it'll get sorted out.

## Limits worth knowing

- Setup needs Terminal once; you won't see it again unless something
  needs fixing.
- If this Mac has never been online since setup, the company folder and
  your own notes may not have arrived yet - they land on first connect.
