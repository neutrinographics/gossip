# Small follow-ups from the inbound-queue design audit

**Track:** Server   **Depends on:** [keep the server's inbound queue under a second in a meeting](server-inbound-queue-under-load.md) (merged first)

## What this is

The 2026-09-21 design audit of the inbound-queue pull request left a
handful of small items that the owner chose not to hold the merge for.
They are grouped here so they are not lost; each is an hour or less.

- **Make the one-process assumption a guard, not prose.** The server's
  in-memory sync state is only valid in a single process; today that is
  written in three places and enforced in none. Heroku names each process
  (`web.1`, `web.2`, …); refusing to serve, or logging an error, when the
  name is not the first web process turns the assumption into a check.
- **Exercise the non-cancellable guards with a real cancellation.** The
  stream-marks cache updates its memory after a commit in a way that cannot
  be cancelled; that is verified by reading, not by a test that cancels.
- **Say in the cache's own words that its rule is the port's.** Its doc
  comment attributes the greater-of rule to the Postgres statement it
  mirrors; the rule follows from the storage interface's stated invariants.
  One test that the cache over the engine's in-memory repository agrees
  with that repository on both marks pins the point, and two named helpers
  (raise the high-water mark, raise the floor) read better than a zero
  meaning "leave the floor alone".
- **One aggregate statement for a stream's byte size.** The status query
  still materialises every row of every stream once a minute to sum their
  sizes; a single `SUM` over the payload lengths does the same.
- **A flaky WebSocket test.** "Every connection in a chain of reconnects is
  ended" occasionally fails with a concurrent-modification error inside its
  own log-capture helper, not in the code under test. A flaky suite hides
  the next regression.

## Related

- The audit: opendoor-api `docs/reviews/2026-09-21-inbound-queue-pr-ddd-ca-audit.md` (CA1-4, T1-2, DDD1-1, DDD1-2, the `sizeBytes` observation).
- Sibling: [give the sync-check its own question to ask](server-sync-check-query-port.md).
