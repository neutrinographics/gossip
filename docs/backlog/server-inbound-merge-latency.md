# Measure how far behind the server's inbound queue runs at the peak of a meeting

**Track:** Server   **Depends on:** nothing

## What this is

Every message a phone sends arrives at the server through one shared
queue, and one worker takes them in order and merges each into the
server's copy of the group's data. If phones send faster than that worker
merges, the queue grows and every message waits its turn. A heartbeat
that says "I am here" is then merged, and forwarded to the other phones,
that many seconds late. This item adds a number to the server's
once-a-minute health line that says how long messages are waiting: the
time from a message's arrival to its merge, or the age of the oldest
message still queued. Nothing else changes until that number says
something.

## Why it matters

In the first meeting on release v48 (2026-09-17), at the busiest minute
(nine to ten phones, 285 merges a minute), a phone that had just
disconnected kept drawing replies from the server for eleven more
seconds, with the registry skipping three operations on the missing peer
for every reply. That is the shape of the phone's already-received
messages still being worked through after it had gone: the queue was
about eleven seconds deep. After every other disconnect that day the
same tail lasted under a second, so this is a peak-load effect. Eleven
seconds is past the app's six-second freshness bound for presence, so
at the peak the other phones would see people flicker in and out. It is
one observation, and the health line today cannot confirm or dismiss it;
the measurement is cheap and the next meeting would answer it for free.

## Rough approach

Stamp each incoming message with its arrival time, and have the merge
path record the delay at the moment it merges. Report the last minute's
maximum and a typical value on the health line next to the merge count.
If the number stays under a second at ten phones, close this item. If it
climbs with the room, the follow-up is in the Kotlin engine's inbound
path: either merge cheaper (the full-stream reads item below is the
obvious cost) or merge in parallel across channels, which the engine's
single-collector design does not allow today and would need its own
ruling.

## Related

- Evidence: [the 2026-09-17 meeting report](../audits/2026-09-17-production-meeting-v48.md), finding 4.
- The likeliest cost inside each merge: [stop the server reading a whole stream to answer a per-author question](server-entry-repository-full-stream-reads.md).
- The phone-side symptom it may explain: the presence flicker noted on the roadmap's measurement item.
