## Unreleased

Accumulated changes since the last consumer pin (2026-05-09, `73f6a58`). Any
publish under the existing pub.dev `gossip` name must version above the old
`gossip-mono` releases (≥ 3.0.0), so these ship as an explicit major release.

### Breaking — wire and limits

- The wire protocol is now versioned. `CoordinatorConfig` gains
  `wireVersion` (`WireVersion.v1` / `WireVersion.v2`), which selects the
  send dialect on both the sync and membership wires; **receive always
  understands both versions**, regardless of the configured send version.
  **Default is `WireVersion.v1`** in every coordinator — the legacy wire:
  unprefixed frames, entry payloads as plain int-array JSON (no base64),
  no `hasMore` key, additive `floor` handling. The previously-documented
  unprefixed-base64 wire (see the old bullet this replaces) no longer
  exists as its own dialect — that encoding is now the explicit v2 wire,
  selected only via `wireVersion: WireVersion.v2`, whose frames carry a
  single-byte `0xF2` version marker that v1-only peers cannot parse.
  Mixed-fleet gossip works only because every node in this release decodes
  both versions; a fleet only changes what it *sends* by flipping every
  node's config to `.v2` together.
- The append-time entry payload cap is now version-dependent, derived from
  `CoordinatorConfig.maxMessageBytes` (default 30 KB budget):
  - **v1 (the default): ~7.4 KB (7552 bytes)** — the legacy int-array
    payload encoding costs ~4 characters per byte, so the same byte
    budget fits far less payload than base64 does.
  - **v2: ~22.1 KB (22656 bytes)** — base64 (~1.33× size) restores the
    larger ceiling.
  `EventStream.append` throws `ArgumentError` above the active cap at
  write time; large delta responses still paginate across gossip rounds
  either way. Practical effect for existing consumers on the default
  config: the append-time payload cap drops to ~7.4 KB until a fleet
  opts into `wireVersion: v2` (which restores ~22 KB). For the Nearby
  transport this is a net improvement — appends over its ~8 KB effective
  send ceiling now fail loudly with `ArgumentError` at `append()` instead
  of silently failing to send. For a WebSocket-backed transport (no such
  ceiling) this is a new constraint: payloads in the ~7.4–22 KB band that
  previously fit no longer do, until the fleet flips to v2.

### Breaking — contracts for repository implementers

- The package was reorganized into bounded contexts (`shared`/`sync`/
  `membership`/`coordinator`); import paths under `src/` changed throughout.
- `EntryRepository.append`/`appendAll` now throw on a duplicate
  (author, sequence) instead of silently ignoring it.
- `EntryRepository.getVersionVector`/`latestSequence` are monotonic
  high-water marks that must survive compaction — persistent
  implementations must store the marks separately from entries.
- `EntryRepository` gained compaction/version-floor surface:
  `removeEntries`, `getCompactionFloor`, `adoptVersionFloor`.

### Breaking — API surface

- `VersionVector.set` and `VersionVector.increment` removed (unused;
  vectors are constructed whole or read).
- `Channel`/`EventStream.registerMaterializer` returns `Future<void>`
  (previously a documented always-empty `Future<List<DomainEvent>>`).
- Local-node invariant violations (`removeMember` of the local node,
  `addPeer` of self) throw typed `DomainException` instead of generic
  exceptions.
- `Coordinator.create(timerPort:)` renamed to `timePort:`.
- `CoordinatorConfig.maxDeltaResponseBytes` renamed to `maxMessageBytes`.
- The public `channelService` field on `Channel`/`EventStream` is gone; it
  existed only as a leak of an internal collaborator — use `Coordinator`
  and the facade methods instead.
- `EntryRepository.entriesForAuthorAfter` removed (unused; implementers
  drop the override).
- `PeerRepository.findReachable`/`exists`/`count` removed (unused;
  implementers drop the overrides).
- `BufferOverflowOccurred` event removed (never emitted; no buffering
  subsystem exists to fire it).
- The phantom domain types `StreamConfig`, `ChannelDelta`, and
  `MergeResult` removed (never constructed by the library).
- `CompactionResult.oldBaseVersion`/`newBaseVersion` collapsed into a single
  `baseVersion` field. `EntryRepository.removeEntries` must never regress
  the version vector, so the two fields could never actually differ —
  compaction reports the stream's (unchanged) version vector once.
- `TimeBasedRetention` and `CompositeRetention` are no longer invocable
  with the `const` keyword — both constructors now validate their
  argument (a non-negative `maxAge`, a non-empty `policies` list), and a
  value-dependent guard is incompatible with const invocation in Dart.
  Construct them without `const`. That validation is a runtime
  `ArgumentError`, not `assert` — `assert` is stripped from release/AOT
  builds, which would otherwise let a negative `maxAge` or an empty
  `policies` list through silently and prune every entry on the next
  compaction. `CountBasedRetention` keeps its `const` constructor and
  `assert`: a negative count still fails loudly at `compact()` time in
  every build mode, via `List.take`'s own unconditional `RangeError`, so
  there is no silent-data-loss gap for a runtime throw to close there.
- `CompactionResult.noChange` removed (unused; construct a
  `CompactionResult` directly with zero counts if a caller ever needs
  one).

### Behavioral

- `StreamCompacted` is now emitted, from `ChannelService.compactStream`,
  whenever a compaction pass actually prunes entries (manual
  `EventStream.compact()` calls and the Coordinator's periodic
  auto-compaction loop alike). Previously declared but never fired.
- A null peer repository is a supported in-memory-only mode (no more
  per-operation storage errors).
- Errors surfacing after `dispose()` are routed to `onLog` instead of
  being dropped.
- Probe scheduling, gossip pacing, and failure-detection internals were
  substantially reworked (SWIM suppression, adaptive pacing, compaction);
  observable protocol behavior is pinned by the test suite, and audit
  records in `docs/audits/` document each change.
- `InMemoryTimePort.advance()` now fires each periodic callback once per
  interval boundary the elapsed time crosses (previously fired every
  periodic callback once per `advance()` call, ignoring the interval).
  Overdue boundaries fire in global deadline order across every live
  timer, not one timer's boundaries exhausted before another's are even
  considered, so a callback that cancels or reschedules another timer
  takes effect on the very next boundary. Each timer's boundary is
  advanced before its callback runs, so a callback that throws still
  consumes that boundary instead of leaving the timer stuck retrying the
  same overdue one on every later `advance()` call.
  `schedulePeriodic` rejects a non-positive interval with `ArgumentError`
  instead of registering a timer `advance()` could never reach.
- `VersionVector` now copies its constructor argument and normalizes
  explicit zero entries away — `VersionVector({a: 0})` equals
  `VersionVector.empty`, and later mutation of the passed map no longer
  alters the vector.

### Added

- Canonical wire conformance vectors under `test/wire_vectors/` — byte-exact
  frames for both wire versions (plus edge cases), the cross-repo source of
  truth that gossip-kt vendors for parity testing.
- Stalled-range suppression: an author range a peer fails to supply
  contiguously is no longer re-requested from that peer at full cadence —
  it is suppressed per (peer, channel, stream, author) and re-probed on a
  doubling backoff (30 s → 10 min cap), lifting automatically the moment
  the range becomes obtainable. No wire change; only the numbers inside
  `DeltaRequest.since` are shaped.

### Changed

- `EventStream.getAll()` now returns `Future<List<LogEntry>>` instead of
  `Future<List<dynamic>>` — the facade was erasing the type that
  `ChannelService.getEntries` already returned. Source-compatible for the
  common `final entries = await stream.getAll()` call site; type inference
  simply tightens.

## 1.0.0

- Initial version.
