# Make the code read cleanly without its comment overlay

**Track:** Code health   **Depends on:** best done after the audit-remediation batches stop churning the same files

## What this is

A dedicated cleanup pass over the library's comments and in-file organization. Today the
code carries three habits that fight the project's own clean-code standard:

1. **Issue-number references in comments.** Dozens of comments cite audit finding keys
   (codes like "CC5-3" or "WIRE4-5") that only mean something to someone who opens the
   audit reports. A maintainer reading the code shouldn't need an external index to
   understand why a line exists.
2. **History and migration commentary.** Some comments describe what the code used to do
   before a refactor, or why a change was made relative to an older shape. That story
   belongs to version control and the audit records, not to the code a new reader sees.
3. **Comment-heavy paragraphs instead of named functions.** Several large files are close
   to 40% comment lines. Where a block of code needs a paragraph to explain *what* it
   does, the block usually wants to become a well-named private function instead, with
   any remaining comment reduced to the *why* the code cannot express.

The pass also covers in-file organization: the biggest classes still use banner-comment
section dividers, which are themselves a sign a file wants splitting or regrouping.

References to architecture decision records stay — those are permanent design documents,
not issue tickets, and pointing at them is ordinary practice.

## Why it matters

Comments that need an external lookup, or that narrate history, are noise for every
future reader and rot silently as the code moves. The project's standard is that code
explains what and comments explain only why; this pass makes the codebase actually meet
that bar instead of meeting it only for new writing.

## Rough approach

File by file, largest first: replace each finding-key citation with the one-sentence
rationale it stands for (or delete it where the code now speaks for itself); delete
history commentary outright; extract commented paragraphs into intention-named private
functions; remove banner dividers by regrouping or splitting. Behavior-preserving
throughout — the full test suite is the net, and the strong invariant comments (the ones
stating things the code genuinely cannot express) are kept and sharpened.

The exact scope of "file organization" (banners only, or also file splits and barrel
conventions) needs an owner decision before planning.

## Related

- [Sweep the remaining minor audit findings](health-minor-findings-sweep.md) — the
  natural neighbor; this item should run after it so the sweep's edits land first.
- The audit records under `docs/audits/` remain the permanent home of the finding
  rationales that comments currently cite.
