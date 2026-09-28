# News wakes a sleeping gossip round — rulings

**Status:** approved 2026-09-27 (see Review outcome); Kotlin half in review as gossip-kt PR #17 (2026-09-28). **Item:** [Wake a sleeping gossip round when there is news](../backlog/engine-news-wakes-the-round.md) (High, confirmed 2026-09-27). **Applies to:** both twins, Kotlin first.

## The finding, restated

Every node paces its gossip rounds with a quiescence pacer: the interval
starts at the active cadence (100–500 ms, jittered ±20 %) and stretches by
1.5× per quiet round toward a 30 s ceiling. News — a local write, a merge, a
delta request sent or received, a peer change — resets the pacer to the
active cadence. But the pacer is consulted only when the *next* wait is
armed, after the current round's wait has elapsed. A wait that was armed at
the stretched interval keeps sleeping through the news.

The node that writes pushes its entry to its peers straight away (the
reactive pusher), so the first hop is prompt. The hub that merges it
resets its pace and then waits out its old wait before it can tell anyone
else. Measured with two phones entering a lesson after a quiet minute
(opendoor-api PR #32's validation, 2026-09-27): the heartbeats reached the
server within a second of the tap; the other phone received them 7.1 s and
8.5 s later, exactly when the server's sleeping round fired. Entering the
lesson again while the pace was still active, the same hop took under a
second. The phones have the same sleeping wait, so a Bluetooth mesh — where
there is no hub to come to a phone — has the same shape between every pair.

## Rulings

1. **The scheduler can be woken.** `LoopScheduler` (kt) and
   `GenerationScheduler` (Dart) gain `wake()`: if a loop is running and is
   *waiting*, and the wait it armed would end later than a fresh
   `nextDelay()` measured from now, that wait is superseded — the generation
   moves on so the stale continuation expires when it fires — and a new wait
   of the fresh `nextDelay()` is armed. In every other case `wake()` does
   nothing: a loop not running, a tick in flight (its next wait will read
   the fresh interval anyway), or a pending wait already shorter than the
   fresh interval (a node at the active cadence is left alone, so a busy room
   does not round on every merge).

   The decision is a rule, so it lives on the value, not in the adapter:
   `Generation` gains the instant its current wait ends (`waitEndsAtMs`,
   null while no wait is armed), `LoopGeneration` gains the pure transitions
   `arm(g, endsAtMs)` and `wake(g, nowMs, freshDelayMs): Transition<Generation, Boolean>`
   — a new generation and "re-arm" when a wait is pending and ends after
   `nowMs + freshDelayMs`, the same generation and "leave it" otherwise —
   and the adapter only executes the answer, as it already does for
   `start`, `stop` and `expire`. The adapter reads `TimePort.nowMs` when it
   arms and when it is woken (infrastructure is where the clock gate allows
   that); the rule takes the reading as an input and is pinned by
   property-style tests. On the Dart side the scheduler still carries its
   own timer state (the port-and-adapter split is a recorded flow-back), so
   the same pure rule sits beside the class there until that flow-back
   lands.

2. **News wakes the round.** The gossip engine's `recordNews()` — the one
   place both twins reset the pacer — calls `scheduler.wake()` after the
   reset, so the first round after news comes within the active interval
   wherever the pacer stood. Nothing else wakes the loop, and nothing wakes
   the failure detector's probe loop: a missed probe already snaps that pacer
   and its cadence is not on the presence path (recorded, not taken).

3. **The bounds do not move.** A woken wait is `nextDelay()` — the jittered
   active interval, never below the 100 ms floor — so wakes cannot round
   faster than the pacing already allows; the idle stretch toward 30 s, the
   growth factor and the ceiling are untouched, and an idle node still costs
   what it costs today. The only behaviour that changes: the wait armed
   *before* the news no longer has to be waited out.

4. **Order of delivery.** Kotlin first (the server is the hub, so that half
   alone brings the fleet's presence relay under a second), released in a
   second small server bump and re-measured with two phones; then Dart in the
   same shape; then the app's pin. Each half lands test-first with the pins
   below; the Dart half checks the twins record news at the same sites and
   puts any difference on the register.

## Pins the plans must carry

- **Scheduler:** with a simulated clock, a wait of 30 s armed → `wake()`
  with `nextDelay()` = 250 ms → the tick runs 250 ms later, not 30 s; the
  superseded wait firing afterwards ticks nothing. `wake()` while a 200 ms
  wait is pending and `nextDelay()` is 250 ms → no change, one tick at
  200 ms. `wake()` while stopped → nothing runs. `wake()` while a tick is in
  flight → exactly one more tick, at the fresh interval after it ends.
  `wake()` racing `stop()` → the loop ends stopped, no tick.
- **Engine:** an engine whose pacer has stretched (several quiet rounds under
  the simulated clock) merges a delta from one peer → its next
  `DigestRequest` to another peer goes out within the active interval of the
  merge, not the stretched one; the same for a local write; the round count
  per minute at active cadence is unchanged (no extra rounds from wakes that
  found a short wait pending).
- **Live:** after the Kotlin half ships to the server, two phones entering a
  lesson after a quiet minute see each other's presence within about a
  second — the measurement that opened this item, repeated.
- **Parity:** the Dart scheduler's tests state the same five cases; the
  register carries any site where one twin records news and the other does
  not.
- **Purity:** `Generation` stays a `data class`; `LoopGeneration.arm` and
  `wake` are pure functions with property-style tests (same inputs, same
  outputs, no mutation); nothing under `domain/` gains a `var`, and the
  adapter gains no state outside its one cell.

## Consumer notes

- kt: `LoopScheduler` gains a member; the library's one adapter implements
  it. opendoor-api implements no `LoopScheduler` and calls none of this —
  the bump is the pin alone.
- Dart: `GenerationScheduler` gains a method; OpenDoorApp constructs no
  scheduler — the app's pin bump carries it to the mesh.

## Review outcome

**Approved (owner, 2026-09-27)**, with the owner's request to check the rulings against DDD and Clean Architecture: the wake decision moved from the adapter onto the `Generation` value as pure transitions (ruling 1, precision), the port/adapter direction and the single news seam confirmed; the Purity pin added.
