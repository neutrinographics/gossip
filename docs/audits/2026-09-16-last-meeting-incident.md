# Incident: the last meeting of 2026-09-16 on release v47

**What this is.** A read of the full server log for the meeting a group
reported as "the app went haywire near the end, presence issues on every
device, could not reach the last page of the lesson". Pulled from the
Papertrail archive (SolarWinds region na-01) after the fact; 33,688 log
lines from 12:37 to 17:45 local (UTC+7). The server was on release v47
(gossip-kt ea0d51c, the receive-loop lifecycle batch); the fixes in
release v48 (session ownership and compaction under load, opendoor-api
PR #22) were deployed at 20:15 the same day, after this meeting.

**Verdict.** Both v48 defects were active for the whole meeting and both
are sufficient to explain the report. One phone received nothing from
the server for 48 minutes in the afternoon and again for 63 minutes up to
the final ten minutes. The presence log grew from 3,613 to 43,585 stored
entries because every compaction tick failed, so every reconnecting
phone's first catch-up pulled a huge presence history. The final ten
minutes were a reconnect storm across all seven phones, and under the
ownership defect each reconnect was a coin toss for going deaf. v48 fixes
the ownership defect and the compaction failure. It does not fix whatever
dropped the sockets, and it does not change digest volume.

## The meeting

| | |
|---|---|
| Window with peers | 12:52 to 17:35 local (282 minutes) |
| Devices seen | 12 node ids, 7 to 8 at once for most of the afternoon |
| Merge batches per minute at steady state | 220 to 260 |
| Bytes out per minute at steady state | 2.4 to 3.3 MB (5.6 MB at the peak of the storm) |
| Stored presence entries | 3,613 at the start, 43,585 at the end, 4,081 six minutes after the room emptied |
| WebSocket sessions opened | 228; median lifetime 109 s; 81 shorter than 60 s; 26 shorter than 10 s |
| "Websocket handler failed: Ping timeout" | 30 (a phone stopped answering pings for 30 s) |

## Finding 1: deaf phones (session ownership, fixed in v48)

Eleven times a phone's new socket registered before its old one was
unregistered. Each time, the old handler's cleanup unregistered the new
session and removed the peer, and the server's sends to that phone hit
"No WebSocket session" until the phone reconnected again.

| Phone (node id prefix) | Deaf from | Deaf until | Sends to nowhere |
|---|---|---|---|
| 5925e3e4 | 13:27 | 14:15 (48 min) | 2,442 |
| 5925e3e4 | 16:15 | 17:18 (63 min) | 2,370 |
| 82e1bf4e | 14:15 | 14:19 | 70 |
| 400c32ea | 13:22, 14:16 | 13:25, 14:18 | 51, 64 |
| f3a99d2f | 14:45 | 14:47 | 40 |
| 6bdcc768 | 16:30, 17:19, 17:21 | 16:31, 17:20, 17:22 | 35, 31, 20 |
| ae8a2a87 | 17:22 | 17:24 | 46 |

A deaf phone still sends, so the others see its heartbeats, but it
receives nothing: no presence from anyone else, and no lesson-state
events. For the phone starting 5925e3e4 that was the last hour of the
meeting.

## Finding 2: compaction never ran (fixed in v48)

Forty compaction ticks failed in a row, one every five minutes from 13:25
to 17:31, each with the Postgres serialization failure on the marks row,
each also escaping as an uncaught worker-thread exception. The presence
stream grew all afternoon to 43,585 entries. The first tick after the
last phone left (17:37) pruned it to 4,081 in one pass.

The cost during the meeting: a reconnecting phone's first delta response
carried whatever presence history it lacked, out of a log that was ten
times its healthy size, over a network that was already dropping sockets.

## Finding 3: the reconnect storm at the end (not a v48 item)

From 17:14 to 17:25 the peer count went 7, 5, 7, 2, 7, 5, 3, 2 minute by
minute. Six phones unregistered within sixteen seconds of each other at
17:18:31 and again at 17:20:30. That is a network event on the phones'
side of the router, not something the server did: a venue Wi-Fi hiccup
or a router-side drop reaches every phone at once. What the server did
wrong under it is Findings 1 and 2: three of the reconnects in that
window double-registered, and every reconnect paid for the swollen log.

Across the whole meeting a socket lived 109 seconds at the median, and
one phone opened 92 sockets. Phones on this network reconnect constantly.
The server's ping period is 15 s with a 30 s timeout; thirty sockets
ended because a phone did not answer a ping for 30 s. Whether that is
the right timeout for phones that sleep and wake is a question for the
roadmap, not this incident.

## Finding 4: sequence holes and floor adoption (library behavior, mitigated by v48)

41 delta responses had a sequence hole (a phone had compacted its own
presence log past what the server had received) and the server adopted a
phone's floor 104 times. Each adoption is a brief gap in that phone's
presence as seen through the server. This is the phone-side compaction
meeting a server that could not compact; with compaction working it
should be rare.

## What v48 changes, and what it does not

- **Fixed:** a reconnect can no longer tear down a phone's live session;
  the old handler is cancelled within a millisecond and the peer stays.
  Compaction succeeds under heartbeat load, so the presence log stays a
  few thousand rows and reconnect catch-ups are small.
- **Not fixed:** the network drops that drove the storm; the ping timeout
  policy; the digest volume (about 97 percent of bytes out, unchanged by
  v48, owned by the digest-scoping and wire-efficiency items); the
  phone-side compaction holes, which should become rare rather than
  disappear.
- **Measurement:** the next meeting on v48 should show zero
  "No WebSocket session" runs longer than a few seconds, a flat
  stored-entry count, and a deaf-phone count of zero. The socket
  lifetime distribution is the number to watch for the network question.

## Raw data

Session scratchpad only (`incident/meeting.jsonl`, the full window;
`incident/health.jsonl`, the day's health lines). Reproducible from
Papertrail for the same window while its retention lasts.
