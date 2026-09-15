# Let the server prune presence while a meeting is running

**Track:** Server   **Depends on:** nothing

## What this is

Every five minutes the server compacts each stream, dropping presence
heartbeats older than the retention window. The pruning step updates a
per-stream floor in the database inside a transaction that must not
overlap with concurrent writes to the same rows. During a meeting, phones
insert a heartbeat every second or two, so the update collides with an
insert almost every time, the database refuses to serialize it, the
library's retry gives up after three immediate attempts, and the pass
fails. It fails again five minutes later, for the whole meeting.

## Why it matters

Three costs, none catastrophic on its own. The presence table grows for
the whole meeting (2,970 to 39,989 rows over three hours on 2026-09-15)
and only shrinks once everyone has left, so a long day is a large table.
Every failed tick prints a full stack trace, burying anything else in the
log. And the failure escapes the database library's asynchronous
transaction helper as an uncaught exception on a worker thread, in
addition to being reported properly through the error callback; that is
the kind of leak that turns into a real problem when a future change
relies on the thread staying clean.

## Rough approach

Make the floor update tolerant of concurrent inserts: take the affected
rows with a row-level lock, or run that statement at a weaker isolation
level, or retry with a short backoff rather than three immediate attempts.
Run the compaction call so a failure surfaces only through the error
callback and never as an uncaught exception. One test that inserts
heartbeats concurrently while a compaction pass runs and asserts the pass
completes. Ship with
[Stop the server from talking to a phone's dead session after it reconnects](server-session-ownership.md).

## Related

- Measured in [the 2026-09-15 meeting report](../audits/2026-09-15-production-meeting-measurement.md), finding F1.
- The retention window and its adaptation were introduced by the
  compaction rollout (opendoor-api PR #16, 2026-08-31); this is its first
  observed failure under real load.
