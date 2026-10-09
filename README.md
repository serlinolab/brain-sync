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

A folder called `Serlinolab` in your home folder, with:

- **Serlinolab_Brain/** — the Serlino brain, kept current on its own. Open the
  Code tab here to work — this is where its rules apply. You can edit it too
  (see "Editing the Brain" below).
- **team/** — notes shared with the whole team. Save something here and
  everyone else sees it within a few minutes. What they save, you see too.
- **personal/** — yours alone, private to this Mac, with three folders inside
  to get you started (`brands`, `ideas`, `finds`).
- **what-changed.md** — a running list of recent changes in the Serlino brain.

From the Brain, Claude also reads what's in your `team/` and `personal/`
folders — you work in one place, and it sees all three.

You never type a command after setup. The only thing you ever click is **Trust workspace**
when you open the Brain (below), and **Fix…** if the brain icon ever turns red.

## The brain in your menu bar

A few minutes after setup, a **brain icon** appears at the top right of your screen, in the
menu bar. It's the **SerlinoLab Brain** app; it installs and updates itself, nothing to do.
Its colour tells you how syncing is going:

- **green** — up to date;
- **yellow** — waiting for Max to approve this Mac (right after setup), or a short hiccup;
- **red** — click it. If it says something needs your attention, open the
  "SOMETHING NEEDS YOUR ATTENTION.txt" file (see below) and do what it says. Otherwise choose
  **Fix…**; if it stays red for more than ten minutes, tell Max;
- **grey** — it can't tell yet (no syncing so far, or this Mac's clock is wrong). If it stays
  grey, tell Max.

It comes back by itself every time you start the Mac. Quitting it never stops syncing.

It needs macOS 14 or later. If no brain icon has appeared ten minutes after setup, tell Max:
syncing still works without it.

## Opening the Brain

1. Click the **brain icon** in the menu bar, then **Open Brain**.
2. Claude opens on the Brain with "get started" already typed in. Press return.
3. Claude asks **Trust workspace** every time. Click it — that's what switches on the Brain's
   rules.

It needs the Claude app installed. The same menu opens your **team folder**, **what changed**,
and the Brain in **Obsidian** if you use it (the first time, in Obsidian choose "Open folder as
vault" and pick the `Serlinolab` folder in your home folder).

You may also have an older **Serlino Brain** shortcut on your Desktop (from before the app
existed, or on a Mac older than macOS 14); it does the same as Open Brain, and the brain menu
offers to remove it.

## Editing the Brain

The Brain folder is yours to edit directly. Save a change to a page in
**Serlinolab_Brain** and it reaches everyone else's Mac within a few minutes; what they
change reaches you the same way. You don't send anything.

A few things stay locked on purpose, and open read-only: the Brain's rules and skills
(every file named `CLAUDE.md` or `AGENTS.md`, and the hidden `.claude` and `.agents`
folders), the **method** folder, and the pages the nightly update writes by itself (the
weekly audit, the stock status, the competitors overview, and the customer-voice summaries
and phrase banks). If you change one of those anyway, the change is not shared: your text is
put aside in `Serlinolab/.state/protected-edits/` and the "SOMETHING NEEDS YOUR ATTENTION.txt"
file tells you where. Nothing is lost.

Editing switches on for each Mac separately, when Max enables it. Until then the Brain
stays read-only, exactly as before. If it is ever switched off again, anything you had
written and not yet shared is kept in `Serlinolab/.state/brain-unsent/`.

## Sharing a skill

A skill is just an instruction — saving one in `team/` never switches it on
by itself. If you've written one you think everyone should use, save it in
`team/` and tell Max. He looks it over and, if it's good, adds it to the
Serlino brain so it applies for everyone.

## Connect MediaBuy (once)

The Serlino brain reads its data from MediaBuy. Without this step it can't see any numbers.

1. In Claude, open **Settings → Connectors**. If **MediaBuy** is already listed, you're done.
2. Otherwise choose **Add custom connector**, enter `https://mcp-mediabuy.maxora.it/mcp`, and
   sign in with your MediaBuy username and password — the same ones you use on the MediaBuy
   website.
3. No MediaBuy login yet? Ask Max; he creates it.

## What leaves your Mac, and what never does

Only `team/` and your changes to the Brain folder leave this Mac, and only to the
company's own shared spaces — never public, never anywhere else. Everything in `personal/` never leaves
this Mac, full stop. That's a fact about how this is built, not a setting
you could turn off.

Because `personal/` never leaves your Mac, it's also never backed up by
this tool. Back it up yourself (Time Machine, iCloud Drive, whatever you
use) if you'd want it back after your Mac is lost, stolen, or wiped.

## If "SOMETHING NEEDS YOUR ATTENTION.txt" appears

If two people write in the same note at the same time, both versions are kept automatically —
you'll never see this file for that. Only a picture or another file that isn't plain text can
still need Max's help. It also appears, for a day, when you changed a locked page in the Brain
(see "Editing the Brain"); it says where your text was kept.

Open it and read it — it explains what's going on in plain language. Your work is never lost when this
appears, and it stays safely on your Mac either way. Send Max a message and it'll get sorted out.

## Limits worth knowing

- Setup needs Terminal once; you won't see it again unless something
  needs fixing.
- On a brand-new Mac, setup may say Apple is installing its own developer tools — if so, click Install, wait a few minutes for it to finish, then paste the same setup line again.
  If Apple instead says the software is "not currently available", download **Command Line Tools** from https://developer.apple.com/download/all/ (sign in with your Apple ID), install it, then paste the setup line again.
- If this Mac has never been online since setup, the Serlino brain and the
  team folder may not have arrived yet — they land on first connect.

## For Max

Provisioning a new person's Mac, and revoking access for one that's lost or
returned, are covered in [`docs/runbook.md`](./docs/runbook.md).
