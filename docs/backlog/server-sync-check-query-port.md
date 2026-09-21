# Give the sync-check its own question to ask, instead of the engine's storage

**Track:** Server   **Depends on:** [keep the server's inbound queue under a second in a meeting](server-inbound-queue-under-load.md) (merged first)

## What this is

The app has a small endpoint a phone calls to ask "am I behind?": it sends
the sequence numbers it holds for its own streams and the server answers
yes or no. Today that endpoint answers by reaching straight into the sync
engine's storage interface — the same one the engine itself uses to merge
and serve data — and asking it for the latest sequence of whatever channel
and stream names the phone put in the request.

This item gives that endpoint its own narrow question ("latest sequence for
this author in this stream"), answered by a small database query of its
own, and stops the endpoint depending on the engine's storage interface at
all.

## Why it matters

Two things. First, the endpoint is open to anyone and the names in the
request are whatever the caller wrote. Since the inbound-queue work, the
engine's storage answers are served from an in-memory table that keeps
every stream it has ever been asked about and loads unknown ones under one
process-wide lock; a caller inventing names can grow that table without
bound and make the engine's own reads wait behind those loads. Second, it
is the wrong dependency in the first place: a web route asking a read-model
question through the engine's persistence port couples the API layer to
the engine's internals, and the interface it pulls in has sixteen methods
where the route needs one. Found twice on 2026-09-21: by the design audit
of the inbound-queue pull request (finding CA1-2) and, independently, by
the automated review on that pull request.

## Rough approach

Define a one-method query interface in the sync context's application layer
("latest sequence for an author in a stream"), implement it on Postgres
with the existing marks table, wire it in the sync module, and have the
route inject that instead of the engine's repository. The engine's storage
interface goes back to having one consumer, the engine. A live-device check
through the tunnel that the "not fully synced" indicator still answers
correctly is the acceptance, since the phone's indicator is the endpoint's
only consumer.

## Related

- Done: opendoor-api PR #26 (merge 989fc15, Heroku v52, 2026-09-21) — `StreamProgressQuery` in the sync domain, `PgStreamProgressQuery` on the marks table; the route no longer references the engine's repository.
- The audit that found it: opendoor-api `docs/reviews/2026-09-21-inbound-queue-pr-ddd-ca-audit.md`, CA1-2.
- The change that made it sharper: [keep the server's inbound queue under a second in a meeting](server-inbound-queue-under-load.md).
