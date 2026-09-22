# Production measurement: the acceptance meeting for the inbound-queue fix (2026-09-22)

**What this is.** The first real room on opendoor-api release v52 (v51's
inbound-queue fix, PR #25, plus the sync-check query port, PR #26, both
deployed 2026-09-21), run to accept or reject the fix against the
criterion set when it shipped: the health line's `wait=` column under a
second, median and maximum, at eight to ten phones. Collected live from
the developer's machine: the Heroku log stream from 04:28 UTC plus one
`GET /admin/sync` snapshot every 30 s (117 snapshots), the buffer's replay
reaching back to 04:14; the stream stalled silently at 05:28:54, so the
last minutes come from a direct `heroku logs -n 300` pull, and the whole
window was pulled again from Papertrail (04:30–05:31, 699 events) as a
cross-check. Times are the server's clock, UTC; the room is on UTC+7.
The phones run the app's current pin of the Dart library (2d6c618). The
server had been up 14 h. Compared against the
[v50 meeting](2026-09-21-production-meeting-v50.md), which measured the
defect with the same room size the day before.

**What the room felt.** The owner reported that getting the devices
together and started took a while, that the room went through a few
pages, and that the meeting was then paused.

**Verdict: accepted.** With eight phones and the room at full traffic,
the inbound queue's wait stayed at a median of 0 ms and a maximum of
120 ms, against 23–27 s the day before at the same count. No socket was
dropped by the ping timeout, no warning or error of any kind was logged,
no phone reconnected over an open socket, no sequence hole or floor
adoption appeared, and the compaction tick after the room emptied pruned
the stored entries. The full room lasted three minutes, which is short,
but the load in them was above the v50 meeting's peak (264 merge batches
and 8.6 MB out in the busiest minute against 172 and 6.4 MB), so the
result is not a light-load artefact. The
[inbound-queue item](../backlog/server-inbound-queue-under-load.md) is done.

## The meeting

| | v50 (2026-09-21) | **v52 (2026-09-22)** |
|---|---|---|
| Window | 10 minutes | **join 05:15–05:24, full room 05:24–05:26, pause 05:26:44, room left 05:28** |
| Devices | 8, all connected throughout | **8 at once (9 node ids; one appeared for 7 s at 04:36)** |
| Merge batches per minute at peak | 172 | **264** |
| Bytes out per minute at peak | 6.4 MB | **8.6 MB** |
| Bytes out per phone per minute | ~700 KB | **~1 MB** |
| Bytes in per minute at peak | 1.4 MB | **2.1 MB** |
| Inbound wait, median / max | 20–25 s / 23–27 s | **0 / 120 ms** |
| Ping timeouts | 13 on six phones | **0** |
| Reconnects over an open socket | 13 | **0** |
| Sends to a phone with no session | 0 | **0** |
| Sequence holes / floor adoptions | 27 / 90 | **0 / 0** |
| Warnings and errors, any class | 32 send failures + holes | **0** |
| Compaction ticks | 3 traced, 1 silent | **05:26 silent, 05:31 pruned 3,415 → 2,832** |
| Stored entries | 2,104 → 3,517 → 2,680 | **2,766 → 3,415 → 2,832** |
| Pending sends / reachable < peers | 0 / never | **0 / never** |
| Heap | 18–34 MB of 256 | **24–66 MB of 256** |

Minute by minute from 05:15, when the first meeting phone joined (`wait`
is median / max of the time a received message sat in the inbound queue;
`gossip` is the server's paced round interval):

| time | peers | merges | in | out | wait | gossip | stored |
|---|---|---|---|---|---|---|---|
| 05:15 | 2 | 0 | 13 KB | 50 KB | 0 / 1 ms | 30 s | 2,761 |
| 05:16 | 3 | 0 | 28 KB | 115 KB | 0 / 4 ms | 30 s | 2,766 |
| 05:17 | 3 | 0 | 7 KB | 51 KB | 0 / 0 | 30 s | 2,766 |
| 05:18 | 3 | 0 | 16 KB | 64 KB | 0 / 0 | 30 s | 2,766 |
| 05:19 | 2 | 0 | 7 KB | 51 KB | 0 / 0 | 570 ms | 2,766 |
| 05:20 | 2 | 0 | 4 KB | 140 KB | 0 / 1 ms | 22 s | 2,766 |
| 05:21 | 3 | 0 | 18 KB | 102 KB | 0 / 1 ms | 30 s | 2,766 |
| 05:22 | 5 | 0 | 27 KB | 158 KB | 0 / 16 ms | 602 ms | 2,793 |
| 05:23 | 7 | 0 | 77 KB | 388 KB | 0 / 2 ms | 15 s | 2,800 |
| 05:24 | 7 | 146 | 1.0 MB | 3.9 MB | 0 / 14 ms | 542 ms | 2,946 |
| 05:25 | 8 | 242 | 1.9 MB | 8.0 MB | 0 / 102 ms | 547 ms | 3,194 |
| 05:26 | 8 | 219 | 1.7 MB | 7.4 MB | 0 / 120 ms | 2 s | 3,415 |
| 05:27 | 7 | 0 | 39 KB | 345 KB | 0 / 0 | 9 s | 3,415 |
| 05:28 | 6 | 0 | 21 KB | 124 KB | 0 / 1 ms | 547 ms | 3,415 |
| 05:29 | 0 | 0 | 0 | 0 | 0 / 0 | 17 s | 3,415 |
| 05:32 | 0 | 0 | 0 | 0 | 0 / 0 | 30 s | 2,832 |

The 30 s snapshots agree and add the sample counts: the queue stamped
1,020–1,359 messages a minute across the three full-room minutes, with a
maximum wait of 102, 120, 120 and 93 ms in the four snapshots that
covered them, and 1 ms again within a minute of the pause.

## Finding 1: the queue keeps up (confirmed, server; the acceptance)

On 2026-09-21 the queue went from empty to 24 s deep within ninety
seconds of eight phones starting to heartbeat, at about eleven frames a
second taken from the queue. Today the server took up to 1,359 stamped
messages a minute, about twenty-three a second, twice the v50 rate, and
the worst any of them waited was 120 ms. The v50 report put the cost at
roughly 90 ms of work per inbound frame, nearly all of it the Postgres
round trips behind every digest reply; PR #25 serves the stream marks
from memory and pushes the delta predicates into SQL, and the number
that the fix was designed to move has moved by more than two hundred
times.

What the room sees follows from it: a page change is read by the server
the moment it arrives and reaches every other phone on its next round,
about half a second at the meeting pace, instead of two minutes. The
owner reported no slow page turns this time.

## Finding 2: no socket was dropped, no warning was logged (confirmed, server)

The ping-timeout cascade of 2026-09-21 (the pinger's pong starved behind
the full queue, six of eight phones dropped in one minute) did not
occur: zero `Ping timeout` lines, zero `Failed to send`, zero
`No WebSocket session` warnings, zero reconnects over an open socket,
and not one WARN or ERROR line of any class between 04:14 and 05:32.
Twelve sockets closed in the window: one phone that appeared for 7 s at
04:36 and one that reconnected after 20 s in the same minute (both
before the meeting, during setup), one meeting phone that dropped at
05:18:54 after 218 s and came back 111 s later, the same phone leaving
at the pause (05:26:44), the other seven leaving together between
05:28:12 and 05:28:18, and the two setup phones' sockets of 52 minutes.
Every one was a clean close followed by `PeerRemoved` in the same
millisecond, with no tail of sends to the departed peer (question 7 of
the runbook: 0 of 12 disconnects had a tail over 2 s).

The one mid-meeting drop (`13a8acdd`, 05:18:54) is the only thing in
the log that the server did not initiate and cannot explain; it came
with 3 phones connected and an empty queue, so it is the phone's side
(sleep, app background, or radio), not the server's.

## Finding 3: the join was slow on the human side, not the server's (observation)

The owner's "took a while to get all the devices together" is visible
as nine minutes of arrivals: 05:15:16, 05:21:32, 05:22:08, 05:22:31,
05:23:10, 05:24:23, on top of two phones that had been connected since
04:36. Each phone was reachable in the second it connected, the queue
was empty throughout, and the server's stored-entry count moved by a
few entries per arrival (its channels were already loaded). Nothing in
the server delayed anyone; the gap between arrivals is people. The v50
read attributed "slow to get everyone in" to the queue filling during
the join; with the queue gone, what remains is the room.

## Finding 4: traffic per phone is ~1 MB out per minute (measured)

Eight phones drew 7.4–8.6 MB a minute from the server in the full room,
about 1 MB per phone against ~700 KB on v50 and ~300 KB on v48. The
increase is the fix working: a server that answers every digest within
milliseconds instead of 25 s later hands out more deltas per minute, and
the phones' own round pace (the server's paced interval sat at 542 ms)
sets the rate. Inbound was 2.1 MB a minute, 260 KB per phone. This is
now the number the
[digest-scoping item](../backlog/engine-scope-digests-to-shared-groups.md)
has to beat, and the split by message type still needs a tunnel run on
the current release: the health line does not carry it.

Per phone, at the peak snapshot (05:25:46), bytes sent to it since it
connected and the server's smoothed round-trip estimate:

| phone (user) | connected | bytes out to it | RTT |
|---|---|---|---|
| `21599df8` (`506fc806`) | 04:36 | 4.2 MB | 273 ms |
| `7476dd3c` (`d307c89b`) | 04:38 | 3.0 MB | 287 ms |
| `132b8168` (`bafc4a4a`) | 05:23 | 2.9 MB | 210 ms |
| `94a852bc` (`b50e193f`) | 05:22 | 2.6 MB | 254 ms |
| `3064532f` (`796a0e50`) | 05:21 | 2.4 MB | 259 ms |
| `13a8acdd` (`f27c3b5a`) | 05:20 | 1.9 MB | 314 ms |
| `e0c67580` (`6e7617c2`) | 05:22 | 1.8 MB | 418 ms |
| `b74dae49` (`4f5f10e2`) | 05:24 | 1.4 MB | not yet measured |

The v50 report's four-and-four split (finding 5 there) cannot be read
from three minutes; the RTT spread is narrower than on 2026-09-21
(210–418 ms against 254–487 ms) and no phone was dropped, so the two
mechanisms that report offered for the slow four (no Nearby path, and
being cycled by the ping timeout) have lost the second one. The
per-phone inbound counters in the snapshot still read a few KB per phone
against 2.1 MB a minute on the health line: they come from the library's
per-peer metrics, not the transport, and do not count inbound gossip
frames (the v50 aside; on the
[server audit follow-ups](../backlog/server-audit-follow-ups.md) item now).

## Finding 5: the silent compaction tick is a tick with nothing to prune (resolved)

The v50 report asked to watch for a compaction tick that logs nothing
(its 04:26 tick). Today's ticks fell at 05:26:23 and 05:31:23 (every
five minutes from the server's start). The first, in the middle of the
room, logged nothing while stored entries kept climbing; the second,
five minutes after the room's traffic, logged `StreamCompacted` and took
the count from 3,415 to 2,832. The library emits the event only when the
retention policy removed something, and the server's presence retention
keeps the last five minutes, so a tick that lands within five minutes of
the room's first entries has nothing old enough to remove and says so by
staying silent. Both silent ticks, then and now, fell inside that
window. Not a defect; nothing to watch.

## What this report cannot see

- A long room. Three minutes at eight phones is enough to show the
  queue keeping up at twice the v50 frame rate, not enough to show a
  slow drift over an hour (the stream-marks cache is bounded by the
  number of streams, so none is expected; the next long meeting will
  say).
- Ten phones. The criterion said eight to ten; eight is what the room
  had. At 23 frames a second and 120 ms worst wait, two more phones do
  not approach the second.
- Bytes by message type (finding 4): a tunnel run on v52 or later.
- The 05:18:54 drop's cause (finding 2): the phone's log.
- The end of the log stream. `heroku logs --tail` stopped delivering at
  05:28:54 with the process still alive and nothing on stderr; the
  collector's health check should compare the tail's last line against
  `heroku logs -n` before the end of a session is trusted (noted for the
  opendoor-api runbook).

## What this changes

- **The inbound-queue item is done.** Acceptance was `wait=` under a
  second at eight to ten phones in a real meeting; it read 120 ms at
  eight, with the ping-timeout cascade, the reconnect churn, the
  no-session sends and the compaction holes all at zero.
- **The ping-timeout policy note stands as written**: the phones were
  never silent and the server now always listens; retuning it would
  have hidden a defect that is now fixed.
- **The digest-scoping item's number to beat is ~1 MB out per phone per
  minute**, higher than every previous meeting because the server now
  keeps up. The re-measure through the tunnel targets v52.
- **The silent compaction tick is explained** and comes off the watch
  list.

## Raw data

Session scratchpad only (`heroku.dedup.log`, 826 distinct lines
04:14–05:32; `snapshots.jsonl`, 117 `/admin/sync` snapshots every 30 s
from 04:28:56; `meeting.jsonl`, the Papertrail pull 04:30–05:31;
`collector.sh`, `status.py`). Reproducible from Papertrail for
2026-09-22T04:30:00Z to 05:35:00Z while its retention lasts.
