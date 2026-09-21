# Production measurement: a short meeting on release v50 (2026-09-21)

**What this is.** A ten-minute meeting on opendoor-api release v50 (v48's
fixes plus the inbound-wait measurement, PR #24, deployed 2026-09-17),
run on the owner's request to read the `wait=` column under a real room.
Collected live from the developer's machine: the Heroku log stream plus
one `GET /admin/sync` snapshot every 30 s, 04:20–04:31 UTC (11:20–11:31
local, UTC+7); the log stream's replay of Heroku's buffer reaches back to
04:13. 814 log events after de-duplication, 20 snapshots. Eight phones
were connected for the whole meeting. The phones run the app's current
pin of the Dart library (2d6c618, before the relay retirement); the
server had been up 18 h. Compared against the
[v48 meeting](2026-09-17-production-meeting-v48.md) (13 phones, 170
minutes) and the [v46 baseline](2026-09-15-production-meeting-measurement.md).

**What the room felt.** The owner reported that getting everyone into
the meeting was slow, and that moving the lesson to its second page took
about two minutes.

**Verdict.** The server's inbound queue is the bottleneck, and it is not
a peak-load curiosity: with eight phones it filled within ninety seconds
of the meeting starting and held a 23–27 s wait for the rest of the
meeting, emptying within a minute of the room going quiet. Everything a
phone sends waits that long before the server reads it, and the backlog
has a second effect that the v48 meeting did not show: once the wait
passes the WebSocket ping timeout, the server drops the socket, so six of
the eight phones were disconnected and reconnected in one minute, and
three of them kept cycling every minute or two after that. Both symptoms
the owner saw are this one queue. Nothing in v48 regressed: every
reconnect was displaced cleanly, compaction ran, no phone went deaf.

## The meeting

| | v46 (2026-09-15) | v48 (2026-09-17) | **v50 (2026-09-21)** |
|---|---|---|---|
| Window | 147 meeting minutes | 170 minutes | **10 minutes** (11:21–11:31 local) |
| Devices | up to 7 | 13 node ids, 9 at once | **8, all connected throughout** |
| Merge batches per minute | 150 | 214 | **172 → 68** (1,276 in all; falling as the room settled) |
| Bytes out per minute, steady state | 3.1 MB | 2.6 MB at 9 phones | **5.6 MB at 8 phones** (53 MB in ten minutes) |
| Bytes out per phone per minute | 710 KB | 295 KB | **~700 KB** |
| Bytes in per minute | — | — | **1.2 MB** (150 KB per phone) |
| Inbound wait, median / max | not measured | inferred ~11 s once | **20–25 s / 23–27 s for nine of ten minutes** |
| Ping timeouts | — | 8 on two phones in 170 min | **13 on six phones in 7 min** |
| Reconnects over an open socket | — | 2, both displaced cleanly | **13, all displaced cleanly** |
| Sends to a phone with no session | 267 | 26 | **0** |
| Sequence holes / floor adoptions | 4 / — | 11 / 13 | **27 / 90**, on one channel's presence stream |
| Compaction ticks failed | 23 | 0 | **0** (ticks at 04:16, 04:21, 04:31; the 04:26 tick left no trace) |
| Stored entries | 2,970 → 39,989 | 3,126 → 5,826 | **2,104 → 3,517 → 2,680** |
| Pending sends / reachable < peers | 0 / never | 0 / never | **0 / never** |
| Heap | fine | peak 116 MB | **18–34 MB of 256** |

Minute by minute (server clock, UTC; `wait` is median / max of the time a
received message sat in the inbound queue):

| time | merges | in | out | wait | gossip | probe | stored |
|---|---|---|---|---|---|---|---|
| 04:21 | 0 | 27 KB | 145 KB | 0 / 95 ms | 30 s | 30 s | 2,104 |
| 04:22 | 172 | 769 KB | 2.8 MB | 0.4 s / 5 s | 734 ms | 30 s | 2,276 |
| 04:23 | 174 | 1.3 MB | 5.2 MB | 15 s / 24 s | 734 ms | 12 s | 2,451 |
| 04:24 | 168 | 1.1 MB | 6.4 MB | 24 s / 26 s | 734 ms | 12 s | 2,640 |
| 04:25 | 164 | 1.0 MB | 6.2 MB | 25 s / 27 s | 734 ms | 2 s | 2,816 |
| 04:26 | 132 | 1.2 MB | 5.9 MB | 24 s / 27 s | 734 ms | 18 s | 2,989 |
| 04:27 | 102 | 1.4 MB | 5.9 MB | 20 s / 23 s | 734 ms | 2 s | 3,123 |
| 04:28 | 103 | 1.3 MB | 5.5 MB | 22 s / 23 s | 734 ms | 12 s | 3,268 |
| 04:29 | 95 | 1.2 MB | 5.3 MB | 23 s / 25 s | 734 ms | 2 s | 3,390 |
| 04:30 | 98 | 1.3 MB | 5.2 MB | 23 s / 24 s | 734 ms | 5 s | 3,517 |
| 04:31 | 68 | 1.1 MB | 5.0 MB | 25 s / 27 s | 734 ms | 2 s | 2,680 |
| 04:32 | 8 | 219 KB | 3.0 MB | 23 s / 27 s | 12 s | 9 s | 2,690 |
| 04:33 | 0 | 33 KB | 262 KB | 0 / 0 | 684 ms | 29 s | 2,690 |

## Finding 1: the inbound queue holds 25 seconds of messages at eight phones (confirmed, server)

This is the question the `wait=` column was added to answer, and the
answer is worse than the 2026-09-17 inference. The queue went from empty
to 24 s deep between 04:22:00 and 04:23:30, as the eight phones started
heartbeating, and stayed there. The reading is a floor: the queue holds
256 messages and once it is full the socket readers block, so frames
behind them wait unstamped. The server took 607–793 frames a minute from
the queue, about eleven a second, which is also the rate eight phones
offer digests at a 734 ms interval before any delta traffic; so the
server spends roughly 90 ms per inbound frame and the phones offer more
than it can take. The moment the room went quiet the queue emptied
(04:33: `wait=0s/0s`), so nothing is leaking; the server is simply slower
per message than the room is fast.

What the room sees: a page change is an entry on one phone. The server
reads it 25 s after it arrives, and every other phone's next delta
request for it waits 25 s too, so the change reaches the rest of the room
a minute or more later, and the reconnect storm below adds catch-ups on
top. Two minutes for a page transition is this queue. "Slow to get
everyone in" is the same queue filling during the join.

Merges per minute fell from 172 to 68 across the meeting while the wait
and the inbound bytes stayed flat, so the cost is not in the entries
merged; it is per frame, mostly digests and delta requests that merge
nothing. That points at the per-message work in the server's inbound
path rather than at storage volume alone (the
[full-stream reads](../backlog/server-entry-repository-full-stream-reads.md)
item is still the likeliest single cost, since every digest reply
consults the stored streams).

## Finding 2: the backlog drops sockets through the ping timeout (new, server)

The server pings each socket every 15 s and closes it if no pong arrives
within 30 s. In the Ktor session, pongs and data frames come off the
socket in one reader loop, and a data frame goes into an eight-slot
channel that the application drains into the inbound queue. When the
queue is full the application stops draining, the eight slots fill, the
reader loop blocks on the ninth data frame, and every pong behind it is
never read. With the measured wait at 23–27 s and the unstamped frames
on top, the effective delay crosses 30 s and the pinger closes the
socket.

That is what the log shows. The queue reached 24 s at 04:23:30; the first
ping timeout came at 04:24:48; by 04:25:56 six of the eight phones had
been timed out and had reconnected, and three of them (`132b8168` three
more times, `0cf455f9` and `7476dd3c` twice more) kept cycling every one
to two minutes until the meeting ended. Fourteen sockets in ten minutes
for eight phones, median lifetime 188 s. Each reconnect was displaced
within a few seconds and drew zero sends to nowhere: v48's session
ownership held, and the 32 "Failed to send: Ping timeout" errors are
sends attempted on the closing socket during those seconds, not a leak.

So the ping-timeout policy note from 2026-09-17 has its explanation:
the phones were not silent, the server was not listening.

## Finding 3: traffic is back at ~700 KB out per phone per minute

Eight phones drew 5.2–6.4 MB a minute in the steady state, about 700 KB
per phone, against 295 KB per phone measured on 2026-09-17 at the same
counts. So the v48 figure was not the stable number, and the digest
scoping item's number to beat is again the v46 one. The health line still
does not split bytes by message type; the split still needs a tunnel
run. One candidate for the difference: with the queue 25 s deep, each
phone's digest is answered against a server view that is 25 s stale, so
every reply carries entries the phone already has, plus the thirteen
reconnect catch-ups.

## Finding 4: compaction holes are the backlog's shadow (library behavior, handled)

27 sequence-hole warnings from five phones and 90 floor adoptions, all on
one channel's presence stream, in five minutes, against 11 holes in the
whole v48 meeting. The phones compact on their own schedule; the server's
view of what they sent runs 25 s behind, so their floors keep overtaking
what the server has received. The library adopted every truncated history
and no data was lost, but the warning volume is a symptom to expect
whenever finding 1 is present.

## What this report cannot see

- Bytes by message type (finding 3): only a tunnel run with a phone's
  log shows the digest share.
- Where the 90 ms per frame goes on the server: the health line has no
  per-message timing; a profile or per-stage timing on the inbound path is
  the next measurement if the fix is not obvious from reading the code.
- Why the 04:26 compaction tick logged nothing: no failure line, no
  event, and stored entries kept climbing until the 04:31 tick pruned
  them. One tick in one short meeting; watch for it.
- The join phase itself: the collector started at 04:20, after the
  phones had connected (04:13–04:16); "slow to get everyone in" is read
  from the queue filling at 04:22, not observed directly.

## What this changes

- **The inbound-latency measurement item is answered:** the backlog is
  real, deep, and present at eight phones, not only at a peak. The
  follow-up it named is now the server's most urgent item: make the
  inbound path cheap enough, or parallel enough, that the wait stays
  under a second in a room of ten.
- **The reconnect churn seen on v48 has a server-side cause** for at
  least part of it, and that part goes away with the backlog. Retuning the
  ping timeout would hide it, not fix it.
- **The digest items get their old number back:** ~700 KB out per phone
  per minute in a meeting. The v48 300 KB figure was one meeting, not
  the trend.

## Raw data

Session scratchpad only (`heroku.dedup.log`, 814 events;
`snapshots.jsonl`, 20 `/admin/sync` snapshots; `collector.sh`).
Reproducible from Papertrail for 2026-09-21T04:10:00Z to 04:35:00Z while
its retention lasts.
