# Stop the server reading a whole stream to answer a per-author question

**Track:** Server   **Depends on:** nothing

## What this is

Two of the server's entry-storage queries read every stored entry of a
stream into memory and then filter or compare in the application: the
batch append reads all existing (author, sequence) pairs of the stream to
check for duplicates, and "entries since a version vector" reads the whole
stream and filters by author sequence afterwards. Both should be expressed
in the query itself so the database returns only the rows that matter.

## Why it matters

Presence streams grow to tens of thousands of rows during a meeting when
compaction is stalled, and to a few thousand even when it is healthy. A
per-batch read of the whole stream turns every merge into a full-stream
scan; the 2026-09-15 meeting ran about 150 merge batches a minute. These
are the next storage costs to hurt once compaction under load is fixed,
and each is a single-statement change at the SQL level.

## Rough approach

Duplicate detection: let the primary key refuse the duplicate and read
back only the batch's own keys, or query `WHERE (author, sequence) IN (...)`
for the batch. Entries since: push the per-author `sequence > since[author]`
predicate into the `WHERE` clause (one `OR` group per author in the
vector). Keep the one-transaction, all-or-nothing behavior of the batch
append. While there, consider giving the blocking-transaction helper a
bounded IO dispatcher (`limitedParallelism`) so queueing for the
ten-connection pool happens in the coroutine scheduler, where it is
visible, rather than inside the pool's connection timeout.

## Related

- Done: opendoor-api PR #25 (2026-09-21), as R2 of the inbound-queue spec; the byte-size walk leftover is on [small follow-ups from the inbound-queue design audit](server-audit-follow-ups.md).
- Surfaced by the final review of the meeting-fixes pull request
  (opendoor-api branch `feature/meeting-server-fixes`, 2026-09-16).
- [Let the server prune presence while a meeting is running](server-compaction-under-load.md)
  — the fix that makes the stream sizes bounded again; this item is what
  remains once it ships.
