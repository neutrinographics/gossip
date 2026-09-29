# Wake a sleeping gossip round when there is news

**Track:** Sync engine   **Depends on:** nothing

## What this is

Every node runs a gossip round on a timer. When nothing new has happened for
a while, the pace stretches, up to one round every thirty seconds, so an idle
device costs little. When something new arrives — a write of its own, or an
entry merged from a peer — the node resets its pace to the fast setting. But
the timer that is already sleeping is not touched: it keeps waiting out the
long delay it armed before the news came, and only the round after that runs
at the fast pace.

The device that wrote something pushes it to its peers straight away, so the
first hop is quick. The second hop is not: the server merges the entry, resets
its pace, and then waits for its sleeping round before it tells anyone else.
Measured with two phones entering a lesson after a quiet minute (2026-09-27):
the first heartbeat reached the server within a second, and the other phone
received it 7.1 and 8.5 seconds later — exactly when the server's sleeping
round finally fired. Enter the lesson again immediately, while the pace is
still fast, and the same hop takes under a second.

The fix: news wakes the round. A node that has just learned something and
finds its round asleep beyond the fast pace re-arms the timer for the fast
pace instead of finishing the long wait. On the server this alone gives the
fleet the benefit, because the server initiates the exchange with each phone:
a phone's own sleeping round does not matter when the server comes to it. The
phones should take the same change so device-to-device meshes get it too.

## Why it matters

Presence in a lesson is the feature people see first, and today it appears
seconds late whenever the room was quiet just before. The delay is not a
transport cost or a server cost; it is one timer that was never told the
situation changed. Waking it is small, and the pacing that saves battery on
idle devices stays exactly as it is.

## Rough approach

Give the scheduler a way to be woken: restart the current wait with the
policy's fresh interval when news arrives and the pending wait is longer than
that interval (a node already at the fast pace is left alone, so a busy room
does not round on every merge). Bound it by the pacing floor and jitter that
already exist. Land it in the Kotlin library first (the server is the hub,
so that half alone fixes presence latency for the fleet), then in Dart in the
same shape — a Bluetooth mesh has no hub to come to a phone, so a phone that
merges news from one neighbour must wake its own round before it can tell
the next — then bump the app's pin so the phones carry it. Pin each half
with a test that arms a thirty-second wait, records news, and sees the next
round within the fast interval; measure the server half again with two
phones before the Dart half ships.

## Related

- Rulings, approved 2026-09-27: [News wakes a sleeping gossip round — rulings](../superpowers/specs/2026-09-27-round-wake-rulings.md).
- Kotlin half: gossip-kt PR #17, merged e78c20a on 2026-09-29. The
  shape it landed: the scheduler port can be woken, the decision is a pure
  rule on the generation value, the adapter holds one cell, and the engine's
  one news seam wakes the loop after resetting the pace. It carries the
  content rule from [the correlation item](engine-response-correlation.md),
  because the wake made that item's misclassification frequent (six of ten
  churn runs) on exactly the path it speeds up.
- Dart half: landed on `feature/dart-round-wake-identity` (2026-09-29; PR
  pending) — the same pure rule on the generation value, the wait's end on
  a `Stopwatch` reading, the scheduler's one timer state moved only by that
  rule's transitions, and the seven news sites checked against kt's seven
  (parity; Dart's one extra site is a register row). It carries the
  pull-identity re-model from [the correlation item](engine-response-correlation.md)
  directly, never the bridge.

- Sibling: [Coalesce wire traffic into fewer radio wakeups](engine-message-coalescing.md)
  (the pacing this item leaves intact); [Only tell a peer about the groups you both belong to](engine-scope-digests-to-shared-groups.md)
  (the other cost measured in the same run).
- Evidence: the opendoor-api live-device validation of the post-remediation
  bump (PR #32, 2026-09-27) — the server log's relay timelines.
- Live pin met: the bump carrying the Kotlin half (opendoor-api PR #33,
  validated 2026-09-29 with the same two phones) — presence within about a
  second both ways after a quiet minute, where PR #32 had measured 7.1 s and
  8.5 s; the server's pacing snapped from 30 s to ~0.5 s on the burst.
- Both libraries share the shape; the scheduler is a port with an adapter on
  the Kotlin side since the architecture remediation (batch E), which is where
  the wake belongs.
