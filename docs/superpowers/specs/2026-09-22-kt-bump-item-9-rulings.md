# The next Kotlin bump (roadmap item 9) — rulings for review

The Kotlin batch that moves the server twin level with the Dart side after
the relay retirement, shipped as its own opendoor-api submodule bump. It
carries the three fixes held back from v47 so that release had one
suspect — the [payload size cap](../../backlog/kt-payload-size-cap.md),
[get-or-create stream access](../../backlog/kt-get-or-create-stream.md),
and the entry-ordering fix from the legacy sweep — plus the three detector
riders the [Dart retirement's review](2026-09-18-dart-relay-retirement-rulings.md)
handed Kotlin, listed on
[the lifecycle follow-ups item](../../backlog/kt-lifecycle-batch-follow-ups.md).
This page carries only the decisions that need the owner's eye before the
Kotlin code moves. The implementation plan follows it and is execution
material, not for review.

Acceptance is fixed in advance: the Kotlin suite stays green with the
pins below in; the server's Postgres repository passes the same ordering
pin as the library's in-memory one; a one-phone tunnel run on the bumped
server shows the stream-creation debug noise gone and the health line
unchanged; no "SWIM" survives in either library's source, README or
CLAUDE.md.

## What Dart does (the shape Kotlin matches)

Read from the Dart library at 9ada5fd, the fleet's pin since
OpenDoorApp PR #501:

- **Payload cap.** `CoordinatorConfig.maxMessageBytes` (default 30 KiB) is
  the wire budget. The codec derives the largest entry payload that fits a
  delta message: budget minus a 512-byte envelope, then ÷ 4 for the v1
  dialect (int-array JSON costs ~4 characters a byte) or ÷ 4 × 3 for v2
  (base64), so 7,552 bytes on v1 and 22,656 on v2. `ChannelService.append`
  throws `ArgumentError` above the cap before the write is even queued;
  the merge path is untouched, since a received entry already fit its
  sender's budget.
- **Get-or-create.** `Channel.getOrCreateStream` asks the service whether
  the stream exists and creates it only if not; the aggregate's
  `createStream` returns false and emits nothing when the stream is
  already there. Two nodes that both start writing to the same stream
  name converge without ceremony, and the library's own test support
  relies on it.
- **Total order.** `LogEntry` is `Comparable`: timestamp, then author id
  (string comparison), then sequence. The in-memory repository's binary
  search inserts on that full comparison, and the repository interface's
  contract says so, because two peers that fold an HLC tie in arrival
  order converge to different derived state.
- **One probe path.** A single `_probe` routine serves the regular round,
  the unreachable-recovery probe and the new-peer bootstrap probe (the
  last without a grace window); the pending ping is dropped in a
  `finally`, so a cancelled round cannot leak it; the Ack handler alone
  records a late Ack's contact; the late-Ack log line carries the sequence.
- **Contact credit per frame.** The sync engine stamps the sender's
  last-contact time and counts the bytes for every inbound frame before
  decoding it, so an old-build peer's relay request still proves its
  inbound path works.
- **Vocabulary.** The mechanism is "failure detection"; the log prefix is
  `[FailureDetector] `; a malformed frame is a "membership message"; the
  probe-interval rationale says the interval is nominally three timeouts
  and a slow peer can overrun it. "SWIM" survives only as the literature
  citation the design departs from.

## Rulings

1. **Scope is the roadmap's, exactly** (owner, 2026-09-22): the three
   held-back fixes and the three riders. Of the legacy sweep only the
   ordering fix rides; the HLC ceiling naming, the dead incarnation
   scaffolding and the other one-liners of the fix inventory's item 13
   stay a later batch, so this server release keeps a short suspect list.

2. **The ordering fix has a server half, and it rides here.** The server's
   Postgres repository orders every stream read by the clock alone
   (`hlcPhysical, hlcLogical`), the same gap as the library's in-memory
   repository; fixing the library without it would leave production
   exactly as divergent as today. Both repositories adopt the total
   order: `LogEntry` becomes `Comparable` (timestamp, author id, sequence),
   the in-memory binary search inserts on it, the interface contract
   states it, and every entry-returning query on the server orders by
   `hlcPhysical, hlcLogical, author, sequence`. No schema change; the
   streams the server holds are a few thousand rows, so the extra sort
   keys cost nothing measurable.

3. **The author tie-break on the server uses byte order.** The ORDER BY
   names `author COLLATE "C"`, so Postgres compares node ids byte by byte,
   which is what Kotlin's and Dart's string comparison do. Node ids are
   ASCII UUID strings, so a locale collation would almost certainly
   agree — but the total order is a cross-node contract and "almost
   certainly" is not one.

4. **The payload cap ports with the same arithmetic.** `CoordinatorConfig`
   gains `maxMessageBytes` (default 30 KiB, validated positive); the sync
   codec gains the budget helper (512-byte envelope; ÷ 4 on v1, ÷ 4 × 3 on
   v2, from the node's configured send dialect); `ChannelService.appendEntry`
   rejects a payload above the cap with `IllegalArgumentException` before
   taking the stream's mutex. The merge path stays uncapped, as in Dart.
   The server authors no entries of its own today — it only merges — so
   the cap is inert there until it does, and the promise to application
   developers is the same on both sides from this release.

5. **The server stops accepting unbounded frames.** Its WebSocket install
   sets `maxFrameSize = Long.MAX_VALUE`. Phones cap their frames at 32 KiB
   by the library's budget, so the server accepts frames up to 64 KiB —
   twice any legitimate frame — and lets Ktor close a socket that sends
   more. This is the "matching frame-size ceiling" the backlog item asks
   for; it rides the same opendoor-api PR.

6. **Get-or-create takes the Dart shape at the aggregate.**
   `ChannelAggregate.createStream` returns whether it created and emits
   `StreamCreated` only then; the service's signature is unchanged;
   `Channel.getOrCreateStream` returns the facade either way. Both
   workarounds go: the Kotlin harness's check-then-act in `TestNode`, and
   the server's two try/catch blocks in `CoordinatorLifecycle` (the
   "stream already exists" debug lines that fill a join — 54 of them when
   the first phone connected on 2026-09-22 — disappear with them). The
   server half rides the bump PR.

7. **The detector gets one probe path, cleaned up in a `finally`.** Port
   Dart's shape: one `probe(target, graceWindow)` for the round, the
   recovery probe and the bootstrap probe; the pending entry is removed in
   a `finally`; the late-Ack contact is recorded by `handleAck` alone, so
   the second stamp in the recovery branch goes; the late-Ack log line
   carries `seq=`. Nothing numeric changes.

8. **Contact credit is stamped once per inbound frame, before decoding.**
   Kotlin stamps at the point where bytes arrive with their sender, ahead
   of the codec chain, and counts the bytes there too; the sync engine's
   own stamp in `handleMessage` is removed so a frame earns credit exactly
   once. This matches Dart to the letter, including that a frame the codec
   rejects still refreshes its sender: it proves the inbound path works,
   which is what freshness suppression keys on. The relay handler keeps
   its byte count and log line and gains nothing else.

9. **The rename sweeps source, tests, README and CLAUDE.md.** Seventeen
   lines in the library's source, four in its tests, five in the README
   and two in CLAUDE.md say "SWIM"; all move to the ruled vocabulary, the
   log prefix becomes `[FailureDetector] `, the malformed-frame text says
   "membership message", and the detector's class doc drops "select random
   reachable peer" and gains the probe-interval overrun caveat. `PingReq`
   keeps its name and its codec (both directions, all fixtures), as on the
   Dart side. The incarnation number keeps its code and only loses the
   word in its doc comments (ruling 1). Historical plan documents under
   `docs/superpowers/plans/` keep the word: they are records.

10. **Sequencing and shape.** One gossip-kt PR on a branch off main, TDD,
    one commit per ruling, with the divergence register rows for entry
    order, get-or-create, vocabulary, contact credit and the probe path
    closed in the same PR, and the three riders struck from the lifecycle
    follow-ups item. Then one opendoor-api PR: the submodule bump, the
    ORDER BY change (ruling 3), the frame ceiling (ruling 5), the
    workaround removal (ruling 6), and a Postgres-backed test that pins the
    ordering on the real repository; live-device validated through the
    tunnel per the runbook, then released. Roadmap item 9 and the two
    backlog items close on the release.

## Pins the plan must carry

- Cap: a 7,552-byte payload appends on v1 and a 7,553-byte one is refused;
  22,656 and 22,657 on v2; the refusal happens before the stream's mutex.
- Get-or-create: two calls for one stream id return the same stream, the
  second emits no event; the harness scenario that writes to a stream
  twice needs no workaround.
- Total order: two entries with an identical HLC from different authors,
  inserted in both orders, read back in the same order on the in-memory
  repository (contract test) and on Postgres (server test); the
  materializer folds them in that order.
- One probe path: a round cancelled during its wait leaves no pending
  ping behind; a late Ack records contact once.
- Contact credit: a relay request from a suspected peer refreshes its
  last-contact time and can clear the suspicion on the next round, on the
  server as on the phone.
- Rename: a source grep for "SWIM" outside the literature citation is
  empty; the log prefix pin reads `[FailureDetector] `.

## Open points for the owner

1. Ruling 5: 64 KiB as the server's frame ceiling (recommended), another
   value, or leave it unbounded.
2. Ruling 3: `COLLATE "C"` on the author tie-break (recommended) or a plain
   `ORDER BY author`.
3. Ruling 8: stamp before decoding, Dart-exact, so a malformed frame still
   earns credit (recommended), or after decoding at the routing point so
   only well-formed frames do.
4. Ruling 10: whether the server's Postgres repository should start
   extending the library's shared contract test (recommended if the fixture
   plumbing is cheap; otherwise a Postgres-only ordering test is the bar).
