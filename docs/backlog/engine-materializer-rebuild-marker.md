# Remember that a view needs rebuilding, even across a crash

**Track:** Sync engine   **Depends on:** nothing

## What this is

Applications can register a "materializer": a small piece of code that folds
the synchronized entry log into whatever shape the app actually wants — a
counter, a document, a list. The library keeps that derived view up to date
by folding new entries into it as they arrive, and periodically saves the
view alongside a cursor marking how far it has folded.

Sometimes entries arrive out of order — a peer hands over an old entry that
sorts *before* entries already folded. The cursor can't help there, so the
library discards the derived view and rebuilds it from the whole log. That
much works today.

The gap: the knowledge "this view needs a full rebuild" lives only in memory.
If the rebuild itself fails to save — a full disk, a storage error — or the
app restarts before the rebuild finishes, that knowledge is gone. On the next
ordinary update the library sees a perfectly valid saved view and cursor,
resumes from the cursor, and the out-of-order entries below it are never
folded in. The view is quietly, permanently missing data that the log still
holds.

## Why it matters

This is silent data loss in the one place users actually look: the derived
view an app renders. The entries themselves are safe in the log and continue
to replicate normally, so nothing detects the divergence — two devices can
show different answers indefinitely, and no error is ever reported.

It takes a conjunction to hit (out-of-order delivery, then a failed save or
an ill-timed restart), so it is not urgent — but the failure is invisible and
permanent, which is exactly the profile that deserves closing deliberately
rather than by accident.

## Rough approach

The rebuild-needed flag has to survive a restart, which means it belongs
next to the saved view rather than in memory. The natural home is the same
place the view and cursor are already persisted — for instance, writing a
cursor value that explicitly means "rebuild from the beginning" before the
rebuild starts, so a crash mid-rebuild is indistinguishable from a rebuild
that never began.

That changes what applications must store and honor, so it is a change to
the materializer contract, not an internal tidy-up: existing implementations
need to keep working, and the migration story wants thinking through before
any code moves.

## Related

- Found during the 2026-08-24 error-context work; the narrower half (an
  out-of-order batch arriving at an uninitialized view now forces a rebuild
  instead of resuming from the cursor) shipped in `dd16e29`.
- [Sweep the remaining minor audit findings](health-minor-findings-sweep.md)
  — sibling audit-hygiene work, but this one is a contract change and does
  not belong in a sweep.
