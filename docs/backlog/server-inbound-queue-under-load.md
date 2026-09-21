# Keep the server's inbound queue under a second in a meeting

**Track:** Server   **Depends on:** nothing (the [full-stream reads](server-entry-repository-full-stream-reads.md) item is the likeliest first step)

## What this is

Every message a phone sends to the server goes into one queue, and one
worker takes them in order, one at a time. In a meeting of eight phones
that worker falls behind within ninety seconds and stays about twenty-five
seconds behind until the room goes quiet. This item is about making the
server keep up: either by making each message much cheaper to handle, or
by handling messages from different groups at the same time, or both,
until a message waits under a second even in a room of ten.

## Why it matters

Measured on 2026-09-21 with eight phones: a 23–27 s wait for nine of the
meeting's ten minutes. Everything the room does goes through that wait
twice (once for the phone that made the change, once for each phone
asking for it), so a page change took about two minutes to reach the
room. Worse, the wait is longer than the server's 30 s WebSocket ping
timeout, and because the pong is read by the same loop that is stuck
behind the full queue, the server closed six of eight phones' sockets in
one minute and kept dropping three of them every minute or two after
that. The 2026-09-17 meeting's reconnect churn and ping timeouts have
this as a cause too. Retuning the ping timeout would hide the symptom;
the queue is the defect.

The server took about eleven messages a second from the queue, which is
also the rate eight phones send their summaries at the meeting's pace, so
the budget is roughly 90 ms of work per message today. Most of those
messages merge nothing: they are summaries and requests, not entries, so
the cost is in answering them, not in storing data.

## Rough approach

Measure first where the 90 ms goes, on the inbound path from the queue to
the reply, with per-stage timing or a profile against a v50 server through
the tunnel. Then, in order of likely payoff: stop reading whole streams to
answer a summary or a per-author question (the sibling item); cache what a
summary reply needs so it is not recomputed per message; and, if that is
not enough, let messages for different groups be handled in parallel,
which the Kotlin engine's single-worker design does not allow today and
needs its own ruling. The wait column on the health line is the acceptance
test: under a second, median and maximum, in a real meeting.

## Related

- Shipped: opendoor-api PR #25 (merge b703e9f, Heroku v51, 2026-09-21); design audit at opendoor-api `docs/reviews/2026-09-21-inbound-queue-pr-ddd-ca-audit.md`. Acceptance is the next real meeting's `wait=` column.
- Spec (for review): opendoor-api `docs/superpowers/specs/2026-09-21-inbound-queue-under-load-design.md` — cached stream marks (R1) and targeted delta queries (R2), which also covers the full-stream reads item.
- Evidence: [the 2026-09-21 meeting report](../audits/2026-09-21-production-meeting-v50.md), findings 1 and 2.
- The measurement that found it: [measure how far behind the inbound queue runs](server-inbound-merge-latency.md).
- The likeliest single cost: [stop the server reading a whole stream to answer a per-author question](server-entry-repository-full-stream-reads.md).
- The phone-side reconnect symptom this explains in part: [reconnect on a silent peer](engine-reconnect-on-silent-peer.md).
