# Production measurement: a real meeting on release v46 (2026-09-15)

**What this is.** The first full measurement of the deployed server under a
real group, collected on the owner's request while the group met, before
the receive-loop lifecycle batch was deployed. It is therefore the
**before** baseline for that release and for the two digest items on the
roadmap. Collected from the developer's machine: the production log stream
(the per-minute `sync-health` line, per-batch `sync-merge` lines, and every
warning) plus one `GET /admin/sync` snapshot per minute.

**Coverage.** 12:27–16:54 local (UTC+7), 181 snapshots. Two gaps: the
Heroku CLI token expired mid-run, so log lines are missing 14:13–14:40 and
snapshots 14:37–15:27; the log stream also stalled silently 16:27–16:40.
The gaps fall inside the meeting, not at its edges, so the shape is
complete. The server was on opendoor-api release v46 (gossip-kt 26e5e24,
the pin before the lifecycle batch); the phones were the 2026-09-02 fleet
app release.

## Headline numbers

| | Meeting minutes (≥20 merges) | Idle minutes with peers |
|---|---|---|
| Minutes captured | 147 | 13 |
| Connected phones (min / median / max) | 2 / 4 / 7 | 2 / 4 / 6 |
| Bytes out per minute, average / peak | 3.1 MB / 5.5 MB | 220 KB / 499 KB |
| Bytes in per minute, average | 562 KB | 6 KB |
| **Bytes out per phone per minute** | **710 KB** (451–1328) | 63 KB (18–161) |
| Merge batches per minute | 150 | 0 |
| Entries merged per phone per minute | 39 | 0 |
| Gossip interval (median) | 1.1 s | 18 s (30 s once settled) |

Totals over the captured 181 minutes: **450 MB out, 81 MB in.** Ten
distinct devices connected during the day; at most seven at once. Pending
sends never rose above zero on any peer, so the server never fell behind
its phones. Heap stayed between 18 and 159 MB of 256 MB, oscillating with
garbage collection, never trending.

**Interpretation.** Presence heartbeats (about 39 entries per phone per
minute, i.e. one every ~1.5 s) keep every phone's gossip round at the
pacer's floor, and every round carries a digest of all ~50 channels the
server holds. With ~40 entries merged per phone per minute at ~500 bytes
each, the entry traffic is around 20 KB; the remaining ~690 KB per phone
per minute is digests. **Roughly 97 % of the server's outbound traffic
during a meeting is digest overhead**, which is what
[digest scoping](../backlog/engine-scope-digests-to-shared-groups.md) and
[recency suppression](../backlog/kt-port-wire-efficiency.md) exist to remove.
Round trips were 400–700 ms median per device, with spikes to 1.5–3.3 s on
three devices.

## Findings

### F1 — Presence compaction fails every tick during a meeting (server)

23 failures, one per five-minute compaction tick from 13:10 until the room
emptied, each `could not serialize access due to concurrent update` from
Postgres inside the entry repository's floor-raising update
(`PgEntryRepository.raiseMarks`, reached from `raiseFloor` inside
`removeEntries`). The ORM retried three times immediately and gave up each
time. While it lasted, no presence entry was pruned: stored entries climbed
from 2,970 to 39,989 (5.7 MB). The first tick after the last phone left
(16:41:38) succeeded and dropped the table to 3,172 entries (1.25 MB).

The same exception also printed as `Exception in thread
"DefaultDispatcher-worker-N"` 23 times: it escaped the ORM's asynchronous
transaction coroutine as an uncaught exception in addition to being
reported through the error callback.

**Severity:** bounded (self-heals after the meeting; storage, not memory)
but real: a meeting-long stream of stack traces, a table that grows all
meeting, and an uncaught exception on a worker thread each time. Server
fix, not library.

### F2 — Sends to a departed peer: 267 warnings, one device accounts for 193

`No WebSocket session for peer` was logged 267 times across the day, 193
of them for one device that reconnected twelve times. This is the known
session-ownership defect: the handler for a session that just closed tears
down by node id without checking the session is still its own, so a phone
that has already reconnected is unregistered by the old handler's cleanup,
and the server keeps addressing the old session. 63 connects and 62
disconnects across ten devices, with 7 websocket ping timeouts (phones
sleeping), gave it plenty of opportunity. Already queued as the next API
fix; today's data makes it the loudest thing in the log.

### F3 — Traffic: ~710 KB out per phone per minute, ~97 % digests

See the headline table. This is the same figure as the 2026-09-03 tunnel
measurement (~650–715 KB) and the 2026-09-15 two-phone tunnel run
(~650–850 KB), now confirmed at seven phones and over two hours: it scales
linearly with phones and does not depend on the tunnel. A four-phone,
two-hour meeting costs the server about 370 MB of egress and each phone
about 85 MB of download.

### F4 — Sequence holes from phone-side compaction: 4 warnings, handled

Four times a phone answered a delta request with a sequence hole in its
own presence stream ("expected 1291, first available 1292"): the phone had
compacted presence entries the server never received. The library's
stalled-range suppression (shipped 2026-09-02) recorded the range and
backed off, as designed; no loop, no error. Recorded as an observation:
the floor-adoption path is doing its job under real churn.

### Healthy

- The server never backed up: pending sends zero on every peer in every
  snapshot, including the 5.5 MB minute.
- Every phone reconnect (63 of them) was handled: unregister, peer removed,
  re-register on the same identity.
- Compaction recovered the whole backlog in one pass once the room emptied.
- The pacer settled to 30 s within a minute of the last phone leaving.
- Heap never trended; the 2026-08-31 memory incident's shape did not recur.

## What this changes

- **Before/after for the lifecycle release.** The next meeting on the
  lifecycle bump (opendoor-api PR #21) should show the same traffic shape
  (the batch did not touch pacing) with steadier merge timing and no
  relay-request stalls; F1 and F2 will still be present until their server
  fixes ship.
- **The digest items now have a per-phone number to beat:** 710 KB per
  phone per minute in a meeting, of which ~20 KB is entries.
- **Two server defects move up the order** (see the roadmap's current
  focus): F2 (session ownership) and F1 (compaction under concurrent
  inserts), best shipped as one opendoor-api pull request with live-device
  validation.

## Raw data

Kept in the session scratchpad only (`prod-monitor/all-snapshots.jsonl`,
`prod-monitor/all-logs.txt`); the numbers above are reproducible from
Papertrail for the same window if needed.
