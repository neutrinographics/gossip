# Normalize formatter drift so diffs stop lying

**Track:** Code health   **Depends on:** nothing

## What this is

Different Dart SDK versions format a few dozen files differently, so any
contributor (or agent) who runs the formatter sweeps unrelated reflow noise
into their diff — several recent reviews had to filter it out by hand, and
one change was nearly committed with 65 reformatted bystander files. This
item runs the formatter once across the monorepo with a pinned SDK, commits
the result as a standalone formatting-only commit, and records the pinned
version so future format runs are no-ops.

## Why it matters

Reviewers verify "this diff changes only what it claims"; ambient reflow
noise makes that verification expensive and hides real changes.

## Rough approach

One formatting-only commit per package (easy to skip in blame), a note in
the root docs naming the SDK/formatter version it was normalized against,
and the format step wired into the standard gate once it is a no-op.

## Related

- Noise incidents recorded in the 2026-08 pacing and restructure review
  trails (Task 2 and Task 3 reviews of the bounded-contexts work).
