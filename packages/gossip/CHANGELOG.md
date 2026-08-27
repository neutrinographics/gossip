## Unreleased

Accumulated changes since the last consumer pin (2026-05-09, `73f6a58`). Any
publish under the existing pub.dev `gossip` name must version above the old
`gossip-mono` releases (≥ 3.0.0), so these ship as an explicit major release.

### Breaking — wire and limits

- Entry payloads are base64-encoded on the wire (~1.33× size). New nodes
  still decode the legacy JSON int-list form, but old nodes cannot decode
  new messages — mixed-version fleets cannot gossip with each other.
- Maximum entry payload is ≈22 KB, derived from
  `CoordinatorConfig.maxMessageBytes` (default 30 KB);
  `EventStream.append` throws `ArgumentError` above it. Large delta
  responses paginate across gossip rounds.

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

### Behavioral

- A null peer repository is a supported in-memory-only mode (no more
  per-operation storage errors).
- Errors surfacing after `dispose()` are routed to `onLog` instead of
  being dropped.
- Probe scheduling, gossip pacing, and failure-detection internals were
  substantially reworked (SWIM suppression, adaptive pacing, compaction);
  observable protocol behavior is pinned by the test suite, and audit
  records in `docs/audits/` document each change.

## 1.0.0

- Initial version.
