# Digest scoping leftovers — short design

**Status:** approved by the owner 2026-11-18 08:18Z (design posted 04:40Z); DDD/cohesion review pass 08:40Z moved channel-creation news off `setChannels` onto `notifyChannelCreated` on both twins.
**Built:** gossip PR #23 and gossip-kt PR #25 (branch `claude/project-thread-22tuwp` in both).
**Applies to:** `gossip` (Dart) and `gossip-kt`, together where behavior changes. No wire change.
**Raised by:** the "Build Dart digest scoping" thread's final report (gossip PR #19,
rulings 5, 6 and 8), before the OpenDoorApp and opendoor-api pin bumps.

## Intent

Four small things PR #19 left behind so its diff stayed reviewable. Three are
code health; one, channel creation as news, is a behavior change both twins
share and the backlog item
[engine-channel-creation-is-news](../../backlog/engine-channel-creation-is-news.md)
already describes. The wall-clock step-back question is **out** — it gets its
own design.

## Goals, non-goals

- Goals: the Dart engine's digest-response seam loses its `pull` flag; the
  rotation value objects' equality is pinned; a locally created channel wakes
  the round on both twins; the three formatter-flagged files are formatted,
  once, in a commit of their own.
- Non-goals: anything on the wire; the pin bumps; channel *removal* or
  pause/resume becoming news (removal is pinned as not news on kt, and resume
  already records news through `start()`); the jitter self-suppression and
  wall-clock items.
- Anti-goal: a formatting sweep that reflows 43 files. The formatter runs at
  the pubspec's language version (3.10), where exactly three files differ.

## Approaches

1. **The pull flag.** (a) Move the running gate inside
   `handleDigestResponse`, as kt's private method does — rejected: nine Dart
   test files call the seam on a never-started engine and expect pulls back.
   (b) **Chosen:** `_onDigestResponse` gates itself: when not running it
   learns holdings and returns; when running it calls the seam, which keeps
   learning and planning. The flag goes; the "paused engine still learns
   holdings" pin stays and keeps passing. Learning keeps one home: a private
   `_learnHoldings(sender, named)` both callers use, so the holdings
   transition is not written twice.
2. **Equality.** `PeerRotation`, `Recency` and `DigestRotation` already
   define `==`/`hashCode`; only `Recency` is pinned. **Chosen:** pin the other
   two the way `recency_test.dart` does. kt's are data classes — nothing to do.
3. **Channel creation is news.** (a) Dart's `setChannels` infers a creation
   from the map growing — rejected on review (2026-11-18, owner asked for a
   DDD and cohesion pass): `setChannels` is a snapshot refresh, and reading a
   domain fact out of a diff puts a policy in a plumbing method. (b)
   **Chosen, both twins:** one engine method, `notifyChannelCreated(channelId)`,
   shaped like `notifyLocalWrite` (no-op unless running, then `recordNews()`):
   the coordinator reports the domain fact, the engine owns the decision that
   it is news, exactly as it does for a local write. The engine's API and
   pins are the same on both sides; only the coordinator's wiring differs,
   for a reason the register records:
   - kt: the coordinator's `onEvent` lambda calls it on `ChannelCreated`,
     beside the `EntryAppended` branch that drives a push. The lambda runs
     under the service's channel lock, so the call must return without
     waiting; `recordNews` only updates a cell and asks the scheduler to
     wake, as `notifyLocalWrite` already does there. The aggregate is saved
     before the event is emitted, and kt engines read the repository, so the
     woken round sees the channel.
   - Dart: `Coordinator.createChannel` calls it right after `setChannels`,
     not from `_onChannelServiceEvent`, because the Dart engine digests a
     snapshot map the coordinator refreshes *after* the service emits
     `ChannelCreated` (an `await _loadChannels()` sits between); a wake
     raised from the event could, in principle, run a round against the old
     map. Ordering the call after the refresh makes the woken round digest
     the new channel. `setChannels` stays what it is.
   `clearPendingFor` / removal stay not news; a `createChannel` for an
   existing channel emits no event on kt and must not notify on Dart
   (the coordinator already short-circuits on an existing facade — verify).
4. **Formatting.** One formatting-only commit for
   `lib/src/sync/domain/aggregates/stalled_range_registry.dart`,
   `test/sync/application/gossip_engine_stalled_range_test.dart` and
   `test/sync/domain/aggregates/stalled_range_registry_test.dart`, produced by
   `dart format --language-version=3.10`. The
   [format-normalization item](../../backlog/health-format-normalization.md)
   gets a note: at the default language version the same formatter changes 43
   files, so the version must be pinned when that sweep runs.

## Pins

- Both, engine: `notifyChannelCreated` snaps the effective interval back to
  the active one and wakes a pending stretched wait (the next `DigestRequest`
  goes out within the active interval, as the local-write pin shows); on a
  stopped engine it does nothing. Dart: `setChannels` alone is not news.
  kt: `clearPendingFor` stays not news.
- Both, coordinator: `createChannel` on a deep-idle running coordinator
  snaps the interval back (the `IdleQuiescence` shape); creating a channel
  that already exists does not. Dart additionally: the first request after
  the creation names the new channel, which pins the call's ordering after
  the map refresh.
- Both, integration: the join scenario's cap drops (Dart `maxRounds` 40 → a
  handful; kt's poll timeout stays, its round count is what the test reports),
  and a pin states that the server's created channel is learned within the
  active interval instead of the backed-off one.
- Dart: `_onDigestResponse` on a stopped engine learns holdings and sends no
  `DeltaRequest` (existing pin); `PeerRotation` and `DigestRotation` equality.

## Delivery

One PR in gossip (code, tests, the three formatted files in their own commit,
backlog item closed, roadmap line, changelog, register row) and one in
gossip-kt (engine method, coordinator wiring, pins). The review pass also added
value equality to the budgeter's result types (`Window`, `OversizedDigest`,
`FittedRequest`, `FittedResponse`), which are data classes on kt and compared
by identity on Dart — the rotation values already had it. Built subagent-driven on
Opus after the plan is approved.

## Left to the builder

Where the Dart join pin's round cap lands
after measuring, and the wording of the register row.
