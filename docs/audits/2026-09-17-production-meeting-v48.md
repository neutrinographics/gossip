# Production measurement: the first meeting on release v48 (2026-09-17)

**What this is.** The after-picture the roadmap's focus item 7 asked for:
the first real meeting on opendoor-api release v48 (the session-ownership
and compaction fixes, PR #22, deployed 2026-09-16 20:15 local), read from
the Papertrail archive after the meeting through the
[production-logs runbook](https://github.com/neutrinographics/opendoor-api/pull/23).
2,520 log events from 08:20 to 11:30 local (UTC+7); the meeting itself
ran 08:32 to 11:23. It is compared against the two before-pictures: the
[v46 baseline](2026-09-15-production-meeting-measurement.md) and the
[v47 incident](2026-09-16-last-meeting-incident.md). The server had been
up since the v48 release (uptime 15 h at the end); no restart during the
meeting.

**Verdict.** Both v48 fixes held under a bigger room than either
before-picture. No phone went deaf: two reconnects arrived while the old
socket was still open and both were displaced within the same second,
with zero sends to nowhere afterwards. Compaction ran on every tick: the
presence log saw-toothed between 4,300 and 5,800 stored entries for three
hours instead of climbing to 43,000. Traffic per phone is now about 300 KB
out per minute, less than half the v46 figure at the same phone count, and
the reason is not established (see finding 3). The network still drops
sockets: 80 sessions for 13 phones, median lifetime 144 s, eight Ktor ping
timeouts on two phones. Nothing in this meeting needs a server change
before the performance items.

## The meeting

| | v46 (2026-09-15) | v47 (2026-09-16) | **v48 (2026-09-17)** |
|---|---|---|---|
| Window with peers | 147 meeting minutes | 282 minutes | **170 minutes** (08:32–11:23 local) |
| Devices | 2 / 4 / 7 (min / median / max) | 12 node ids, 7–8 at once | **13 node ids, 9 at once for 66 minutes, 10 at peak** |
| Merge batches per minute, steady state | 150 | 220–260 | **214** (35,516 in all) |
| Bytes out per minute, steady state | 3.1 MB average | 2.4–3.3 MB | **1.8 MB at 6 phones, 2.6 MB at 9** (359 MB in all) |
| Bytes out per phone per minute | 710 KB | ~340–410 KB | **295 KB** (mean; median 293) |
| Entries merged per phone per minute | 39 | — | **29** |
| Stored presence entries | 2,970 → 39,989 | 3,613 → 43,585 | **3,126 → peak 5,826 → 4,368; 3,880 after the room emptied** |
| Compaction ticks failed | 23 | ~40 | **0** (52 compaction events) |
| Sends to a phone with no session | 267 | thousands (deaf phone) | **26**, 25 of them within one second of that phone's disconnect |
| Deaf-phone runs | — | 48 min and 63 min on one phone | **0** |
| Reconnects while the old socket was open | — | 11, each a coin toss | **2, both displaced cleanly** |
| WebSocket sessions opened | 63 reconnects | 228; median lifetime 109 s | **80; median lifetime 144 s** |
| Ping timeouts | — | 30 | **8** (two phones) |
| Pending sends above zero | never | — | **never**; reachable = peers every minute |
| Heap | never trended | — | **median 32 MB, peak 116 MB of 256** |

The gossip interval sat at its 1 s floor for 166 of the 170 minutes and
the probe interval at 30 s for most of them; both settled within a minute
of the last phone leaving, as on v46.

## Finding 1: session ownership held (fixed in v48, confirmed)

Twice a phone opened a new socket before the server had seen the old one
close: node `f3a99d2f` at 08:35:04 and node `1c44ab91` at 09:00:24 local.
Each time the log shows, in the same second, "Client reconnected before
its old connection closed", "Client connection closed after being
replaced", and the new "Client connected". Neither phone drew a single
"No WebSocket session" warning afterwards. On v47 the same event removed
the live session eleven times and left one phone deaf for an hour.

Of the 26 "No WebSocket session" warnings, 25 came within one second of
that phone's own disconnect — the sends already in flight when the socket
went, which is the normal shape. The one exception is finding 4.

## Finding 2: compaction ran all meeting (fixed in v48, confirmed)

Zero "Compaction failed" lines. The stored-entry count on the health line
rose about 180 a minute between ticks and fell back on each tick,
oscillating between roughly 4,300 and 5,100 for the second half of the
meeting; the peak, 5,826, was in the first hour while nine phones were
joining. On v46 and v47 the same count reached 40,000 because every tick
collided with the heartbeat inserts. A consequence worth stating: every
reconnect catch-up this meeting pulled a few thousand presence entries at
most, never a whole afternoon.

## Finding 3: traffic per phone is 295 KB out per minute, not 710 KB

Bytes out per minute by connected phones, averaged over the meeting:

| Phones | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---|---|---|---|---|---|---|---|---|---|
| KB out / min | 149 | 780 | 1,331 | 1,666 | 1,814 | 2,041 | 2,324 | 2,616 | 2,697 |
| KB per phone | 75 | 260 | 333 | 333 | 302 | 292 | 291 | 291 | 270 |

The per-phone rate is flat from four phones up, at about 300 KB, against
710 KB on v46 at the same counts. The drop is already visible in the v47
read (about 340–410 KB at seven to eight phones), so it sits between v46
and v47. The lifecycle batch did not touch pacing or digest size, and the
per-minute health line does not split bytes by message type, so this
report cannot say what the missing 400 KB was. The likeliest candidate is
that the v46 figure included reconnect catch-ups against a presence log
that compaction was failing to prune, which are entries, not digests; on
that reading the v46 report's "97 % digests" split, taken from the tunnel
with one phone, was never true of the meeting. **This matters for the
digest-scoping item:** its number to beat is now about 300 KB per phone
per minute, and the digest share should be re-measured through the tunnel
against a v48 server before that spec sizes its win.

## Finding 4: eleven seconds of inbound backlog at peak load (observation, gossip-kt)

Node `f2eb93c4` disconnected at 09:06:59 local and its peer was removed in
the same second, yet between 09:07:01 and 09:07:10 the server tried to
send to it twelve more times, and the peer registry skipped 35 operations
on the missing peer over the same eleven seconds. The phone reconnected at
09:07:41 and lost nothing a reconnect catch-up does not fetch.

The round loop cannot explain this: it reads the reachable list fresh each
round and the health line shows the peer gone at 09:07. The ratio does:
about three skipped operations per send is the shape of an inbound
message from that phone being processed after its removal (the contact
and received-bytes updates are skipped, then the reply finds no session).
The server feeds every phone's messages into one shared flow with a
256-message buffer and one collector that merges them in order, so the
reading is that at 09:07 that queue held about eleven seconds of
messages. It was the busiest minute of the meeting: nine to ten phones,
285 merges a minute, 3.4 MB out. After the other 25 disconnects the same
tail lasted under a second, so the backlog is a peak-load effect, not a
constant. Its meeting-visible form would be presence arriving at other
phones several seconds late at the peak, which is within reach of the
app's 6 s freshness bound. Worth a look in the Kotlin engine's inbound
path before the room grows further; a merge-latency figure on the health
line would settle it.

## Finding 5: the network still drops sockets (not a server defect)

Eighty WebSocket sessions served thirteen phones over 170 minutes: 28 an
hour, against 48 an hour on v47. Lifetimes: 17 under 30 s, 22 between
30 s and 2 min, 18 up to 10 min, 12 up to 30 min, 4 up to an hour, and 7
longer than an hour (the longest, 2 h 49 min, was a phone that stayed
connected for the whole meeting). Four phones reconnected 12 to 14 times
each. Reconnect gaps: median 31 s, 13 within 5 s, 19 longer than a minute.

Eight sessions ended in a Ktor ping timeout (15 s ping period, 30 s
timeout), all on two phones: node `e88bc027` three times between 08:37 and
08:45, node `6bdcc768` five times through the meeting. The other 70
disconnects were the phone's side closing. The ping-timeout policy is
still the open question from the v47 incident: a phone that answers
nothing for 30 s is usually a phone that has lost the network, and the
reconnect that follows costs one catch-up, which is now small.

## Finding 6: phone-side compaction holes, handled (library behavior)

Eleven "sequence hole" warnings (five from one phone) and thirteen
"adopted truncated history" lines, all on presence streams. The
stalled-range suppression and floor adoption did their job; no loop, no
error, no pending build-up. Same shape as v46's four and v47's, at a
bigger room.

## What this report cannot see

- The half-second presence flicker seen through the tunnel on 2026-09-16
  is a phone-side observation; the server log has nothing to say about it.
- Bytes by message type (finding 3); only the tunnel with a phone's log
  shows that.
- Why phones close their sockets: the server sees the close, not the cause.

## What this changes

- **Focus item 7 is done.** Both v48 fixes are confirmed under a real
  ten-phone meeting; no server change is needed before the performance
  work.
- **The digest items get a new number:** about 300 KB out per phone per
  minute, and the digest share needs re-measuring on v48 before the
  digest-scoping spec claims a saving.
- **Two small follow-ups to consider,** neither urgent: the ping-timeout
  policy (finding 5) and the inbound backlog at peak load in the Kotlin
  engine (finding 4).

## Raw data

Session scratchpad only (`meeting.jsonl`, the full window;
`health.jsonl`, the day's health lines; `analyze.py`, the runbook's six
questions as a script). Reproducible from Papertrail for
2026-09-17T01:20:00Z to 04:30:00Z while its retention lasts.
