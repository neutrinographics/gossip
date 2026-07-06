---
name: roadmap
description: >-
  Maintain this project's development roadmap and backlog (docs/roadmap.md +
  docs/backlog/). Use this whenever a feature or idea surfaces that should be
  captured for "someday," when adding/updating/splitting/merging roadmap items,
  when changing an item's priority or status, when marking something done, or
  when reviewing the roadmap. Trigger it even for casual phrasings like "add
  that to the backlog," "put it on the roadmap," "we should do X eventually,"
  "mark checking as done," "bump wordMAP to high," or "what should we do next?"
  — anything that touches the roadmap or backlog. Prefer this skill over editing
  those files ad hoc, so the conventions stay consistent across sessions.
---

# Maintaining the roadmap

This project tracks future work in two places that play distinct roles. Keeping them
distinct is the whole point — it's what stops the roadmap from rotting into a stale
task list. Read this before touching either file.

## The two files and their jobs

- **`docs/roadmap.md`** — the *index*. It owns **priority**, **status**, ordering, the
  short one-line summary of each item, and the project's design invariants (guardrails).
  It is the at-a-glance overview and checklist.
- **`docs/backlog/<slug>.md`** — one *stand-alone description* per item. It owns the
  *timeless* explanation of the feature/idea: what it is, why it matters, roughly how,
  and what it relates to. One item = one file.

**The one rule that prevents drift:** priority and status live **only** in the roadmap,
**never** in a backlog file. A backlog file describes the idea as if priority didn't
exist — because priorities change constantly and duplicated state always goes stale. If
you ever find yourself typing "High" or "in progress" into a backlog file, stop: that
belongs in the roadmap.

## This is a feature/idea list, not a rigid task list

Items are *ideas and features*, not tickets. As understanding grows, freely **split** one
item into several, **merge** small or overlapping ones, **rename**, or **re-prioritize**.
Don't treat the current shape as fixed. When new information changes how you'd describe
something, rewrite the description — that's the system working, not a failure of planning.

## Tracks

A *track* is a grouping of related items. It does double duty: it's the section heading an
item sits under in the roadmap, and it's the prefix on the item's backlog slug. Tracks keep
the roadmap scannable by theme — all the checking work together, all the launch-readiness
work together.

The **current tracks are the section headings in `docs/roadmap.md`** — read them there rather
than trusting a list memorized here, which would drift (the same reason priority and status
live only in the roadmap). At the time of writing they are: Checking, Alignment, Persistence,
Source data, Quality, Product, Code health, and Launch readiness (whose slug prefix is
`deploy-`). Treat the roadmap as the source of truth; this list is only an orientation.

Put a new item in the **closest existing track**. Only coin a new track when an item clearly
belongs to a distinct area of work that several current or foreseeable items would share — a
"track of one" is usually a sign the item really fits an existing track. Adding a track is
cheap and reversible: it's just a new roadmap section heading plus a new slug prefix, nothing
to register elsewhere. If a track ends up empty after a split/merge, remove its heading.

## Backlog file format

Each file is written so a person with **zero project context** can understand it. Plain
language, no codebase jargon, no internal type names or file paths in the prose (mention
those only in "Related" as links). If a domain term is unavoidable (e.g. "alignment"),
explain it in a sentence. The reader should come away knowing what the thing is and why
it's worth doing.

Use this shape:

```markdown
# <Plain, descriptive title — a human sentence, not a code symbol>

**Track:** <Track>   **Depends on:** <other item titles, or "nothing">

## What this is
Plain-language description someone with no project context can follow.

## Why it matters
The value it delivers or the problem it solves.

## Rough approach
High-level shape only — no deep implementation detail. Omit if genuinely unknown.

## Related
Links to a spec/plan (if one exists) and to sibling backlog items, as
[markdown links](other-item.md). This is where technical references belong.
```

Some items (like the "why direct beats indirect" reasoning on an alignment item) warrant an
extra short section — add one when it genuinely helps a cold reader. Keep it plain.

**Slugs** are kebab-case, prefixed by their track so the folder browses by theme
(e.g. `checking-real-findings.md`, `deploy-session-memory-cap.md`). See **Tracks** above for
the current set and for when to coin a new prefix.

## Roadmap line format

In `docs/roadmap.md`, each item is one checklist line under its track:

```
- <status> **<Priority>** — [<Title>](backlog/<slug>.md) · <one-line summary>
```

- **Status:** `☐` not started · `◐` in progress · `☑` done
- **Priority:** `High` · `Medium` · `Low` · `Launch` (gated to before public exposure)

The title in the roadmap line should match the backlog file's `#` title (or be a faithful
short form of it).

## Operations

**Add an item.** Create `docs/backlog/<track>-<slug>.md` using the format above, then add a
line to the roadmap under the right track with a status and a proposed priority. If it
depends on or relates to existing items, wire the "Related"/"Depends on" links both ways.

**Update status or priority.** Edit only the roadmap line. Don't touch the backlog file for
this — nothing about status/priority lives there.

**Split an item.** Write the new backlog files, replace the old roadmap line with the new
ones, delete the old backlog file (or repurpose it as one of the new ones), and fix any
links that pointed at the old slug. Leave nothing dangling.

**Merge items.** Write one combined backlog file, replace the several roadmap lines with one,
delete the now-unused backlog files, and repoint inbound links.

**Mark an item done.** Flip the roadmap status to `☑`. Add a brief note on the line (or a
short "Done" line in the backlog file's Related section) pointing at the shipping commit or
spec, so the record survives. Consider whether a done item spawns follow-ups worth adding.

**Review the roadmap.** Read the roadmap top to bottom. Check: does each item still make
sense, are priorities still right, has anything shipped that isn't marked done, did recent
work surface ideas that were never captured? Surface adjustments to the user rather than
silently rewriting priorities — priority is theirs to set.

## Before you finish — hygiene checks

- **No dangling links.** After any add/split/merge/delete, grep the docs for the changed
  slug and fix references (`grep -rn "<slug>" docs`). Broken links erode trust in the doc.
- **One item, one file.** No orphan backlog files without a roadmap line, and no roadmap
  line without a backlog file.
- **Plain language held.** Re-read new backlog prose as a cold reader — did jargon creep in?
- **Status/priority didn't leak** into a backlog file.
- **Keep MEMORY / other pointers honest** if you deleted or renamed a file other docs
  reference.
