# Digest scoping leftovers — short design

**Status:** approved by the owner 2026-11-18 08:18Z (design posted 04:40Z).
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
   holdings" pin stays and keeps passing.
2. **Equality.** `PeerRotation`, `Recency` and `DigestRotation` already
   define `==`/`hashCode`; only `Recency` is pinned. **Chosen:** pin the other
   two the way `recency_test.dart` does. kt's are data classes — nothing to do.
3. **Channel creation is news.** (a) A new engine method the coordinator
   calls. (b) **Chosen for Dart:** `setChannels` records news when the map
   gains a channel it did not hold — the coordinator already calls it on
   create and remove while running, and a removal gains nothing. (c)
   **Chosen for kt:** a public `GossipEngine.notifyChannelCreated()`, shaped
   like `notifyLocalWrite` (no-op unless running, then `recordNews()`), called
   from the coordinator's `onEvent` lambda on `ChannelCreated` — the same seam
   that turns `EntryAppended` into a push. That lambda runs under the
   service's channel lock, so the call must return without waiting;
   `recordNews` only updates a cell and asks the scheduler to wake, which is
   what `notifyLocalWrite` already does there. kt has no `setChannels`: its
   engines read the repository every round, so (b) has no kt twin. Record the
   seam difference in the register.
4. **Formatting.** One formatting-only commit for
   `lib/src/sync/domain/aggregates/stalled_range_registry.dart`,
   `test/sync/application/gossip_engine_stalled_range_test.dart` and
   `test/sync/domain/aggregates/stalled_range_registry_test.dart`, produced by
   `dart format --language-version=3.10`. The
   [format-normalization item](../../backlog/health-format-normalization.md)
   gets a note: at the default language version the same formatter changes 43
   files, so the version must be pinned when that sweep runs.

## Pins

- Dart, engine: `setChannels` with a new channel snaps the effective interval
  back to the active one and wakes a pending stretched wait (the next
  `DigestRequest` goes out within the active interval, as the local-write pin
  shows); `setChannels` with the same set, or a smaller one, is not news.
- kt, engine: `notifyChannelCreated()` is news while running and nothing
  when stopped; `clearPendingFor` stays not news.
- kt, coordinator: `createChannel` on a running coordinator wakes the round;
  creating an existing channel again does not.
- Both, integration: the join scenario's cap drops (Dart `maxRounds` 40 → a
  handful; kt's poll timeout stays, its round count is what the test reports),
  and a pin states that the server's created channel is learned within the
  active interval instead of the backed-off one.
- Dart: `_onDigestResponse` on a stopped engine learns holdings and sends no
  `DeltaRequest` (existing pin); `PeerRotation` and `DigestRotation` equality.

## Delivery

One PR in gossip (code, tests, the three formatted files in their own commit,
backlog item closed, roadmap line, changelog, register row) and one in
gossip-kt (engine method, coordinator wiring, pins). Built subagent-driven on
Opus after the plan is approved.

## Left to the builder

The exact shape of the growth check in `setChannels` (a key-set difference is
enough; no need to diff aggregates), where the Dart join pin's round cap lands
after measuring, and the wording of the register row.
