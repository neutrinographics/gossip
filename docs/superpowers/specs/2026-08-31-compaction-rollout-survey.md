# Consumer survey: what the compaction update costs the API and the app

**Date:** 2026-08-31   **Status:** survey complete, no code changed
**Scope:** what it takes to ship compaction as a stable update to the server
(`opendoor-api`) and the mobile app (`OpenDoorApp`), without losing stability
or functionality, and without moving the wire.

The authority for the contract changes is `packages/gossip/CHANGELOG.md`
("Unreleased" — accumulated since the consumer pin `73f6a58`, 2026-05-09).

## Headline

Both consumers need the same two repository methods and little else. The one
finding that changes behaviour for real users is the payload cap: **a lesson
response that is legal today can become an `ArgumentError` after the update,
but only in non-Latin scripts.** Everything else is mechanical.

Two of the three known library defects cannot affect the server, and the third
is pre-existing. Compaction on the server prunes nothing until a retention
policy is chosen deliberately.

## 1. The payload cap — the only user-visible regression risk

`EventStream.append` now rejects oversized payloads at write time. The cap is
derived from `CoordinatorConfig.maxMessageBytes` (default 30 KB) and depends on
the wire dialect: **7552 bytes on v1 (the default), 22656 on v2.**

`LessonResponseSubmittedEvent.validate()` limits the response to **5000
characters** — a character limit, against a byte budget. Measured envelope
overhead is 426 bytes, leaving 7126 bytes for the response text:

| Script | bytes/char | fits in v1 | app allows | verdict |
|---|---|---|---|---|
| Latin / ASCII | 1 | 7,126 | 5,000 | fine |
| Greek, Cyrillic, Hebrew, Arabic | 2 | 3,563 | 5,000 | throws above ~3,563 chars |
| CJK, Devanagari, Thai, Amharic | 3 | 2,375 | 5,000 | throws above ~2,375 chars |
| Emoji-heavy | 4 | 1,781 | 5,000 | throws above ~1,781 chars |

**This is not purely a regression.** Per the changelog, the Nearby transport has
an ~8 KB effective send ceiling, and payloads above it *already* fail silently
today — they are accepted by `append()` and then never delivered. The update
converts silent non-delivery into a loud error at the point of writing. The
defect exists now; the update makes it visible.

**Recommended fix (app):** validate the response by UTF-8 **byte** length rather
than character count, bounded below the v1 budget, with a message the user can
act on. A character limit cannot express this constraint in a multilingual app.

## 2. Repository contract — both consumers

Both `PgEntryRepository` (server) and `HiveEntryRepository` (app) are missing
exactly the same two members, and nothing else: **`getCompactionFloor`** and
**`adoptVersionFloor`**. The interface went 14 → 16 members.

Two behavioural clauses come with them:

- **Duplicate appends must throw.** Both implementations currently ignore
  duplicates silently — the app does so explicitly (`if (isDuplicate) return;`).
- **`getVersionVector`/`latestSequence` are monotonic high-water marks that must
  survive compaction**, which means storing them apart from the entries.

**The app violates the second clause today, and it is compacting in
production.** `removeEntries` calls `_rebuildSequenceCache(...)`, which
recomputes the vector from the *surviving* entries, so every compaction pass
regresses the version vector; `_loadFromBox()` rebuilds it the same way at
startup. Presence is compacted on a 6-second horizon, so this happens
constantly on a live device. This is the version-vector-regression bug class the
new contract exists to prevent — the update fixes a live defect rather than
introducing risk.

## 3. Everything else in the checklist

Surveyed across the app; hit counts are call sites found:

| Change | Hits | Action |
|---|---|---|
| `Coordinator.create(timerPort:)` → `timePort:` | 1 | rename |
| `maxDeltaResponseBytes` → `maxMessageBytes` | 0 | none |
| `channelService` field removed | 0 | none |
| `VersionVector.set`/`increment` removed | 0 | none |
| `const TimeBasedRetention` / `CompositeRetention` | 0 | none |
| `BufferOverflowOccurred` removed | 0 | none |
| `StreamConfig` / `ChannelDelta` / `MergeResult` removed | 0 | none |
| `CompactionResult.oldBaseVersion`/`newBaseVersion` | 0 | none |
| `CompactionResult.noChange` removed | 0 | none |
| `PeerRepository.findReachable`/`exists`/`count` removed | 0 | app implements no `PeerRepository` |
| `registerMaterializer` now returns `Future<void>` | 0 used as a value | none |
| `entriesForAuthorAfter` removed from the interface | 1 (app) | harmless extra method; delete when convenient |

The app also carries a workaround comment at `coordinator_sync_service.dart:287`
("createChannel always overwrites with a fresh aggregate that has no streams").
That is the bug the get-or-create fix closed; the workaround becomes redundant
but harmless.

## 4. Why the known library defects do not block this

- **`stop()` does not stop / restarts stack collectors.** The server calls
  `start()` once on `ApplicationStarted` and `stop()` once on
  `ApplicationStopped`, and the process exits immediately after — the defect
  needs a restart cycle in a living process, which never happens here.
- **Indirect probing is inert.** Present at the current pin too; not a
  regression, and it degrades failure detection rather than data.
- **Swallowed cancellation.** Shutdown-path noise only.

## 5. Compaction is inert on the server until asked for

The server creates streams with no retention policy, which defaults to
`KeepAllRetention`, and the auto-compaction sweep skips streams whose policy
retains everything. Shipping the update therefore changes no server data.

For the planned presence sync, that default is the wrong one — see the growth
analysis below.

## 6. Presence growth, if compaction stays off

Heartbeat cadence is one entry per device per **2 seconds**
(`PresenceController._heartbeatInterval`; `kPresenceTtl` is 6 s). Cost per entry
in Postgres is ~530 B — 232 B heap plus ~298 B across the primary key and the
two indexes.

| Fleet | Entries/week | Disk/week | Per year |
|---|---|---|---|
| 20 devices × 1 h/wk | 36,000 | 19 MB | ~1.0 GB |
| 20 devices × 2 h/wk | 72,000 | 38 MB | ~2.0 GB |
| 100 devices × 2 h/wk | 360,000 | 191 MB | ~9.9 GB |

Storage is not the constraint; Postgres is untroubled by this. **The constraint
is that the Kotlin engine does not paginate deltas** — `GossipEngine.kt:317`,
"kt sends complete deltas; no pagination yet", and paging remains open scope on
the wire campaign. A device joining a group with an empty version vector for the
presence stream receives **one** response carrying everything the server holds:

| Server retains | Entries | One delta payload |
|---|---|---|
| 1 minute | 600 | 0.1 MB |
| 15 minutes | 9,000 | 0.9 MB |
| 1 hour | 36,000 | 3.7 MB |
| one 2-hour session | 72,000 | 7.3 MB |
| one year | 3.7M | 382 MB |

A single session's accumulation already produces a multi-megabyte message
against a client whose own payload ceiling is ~7.4 KB. The server's
`maxFrameSize` is `Long.MAX_VALUE`, so nothing refuses it. Existing devices are
unaffected — they hold current version vectors — so this fails only when a new
or reinstalled device joins an established group, which is exactly the case that
gets no testing until it happens.

**Leaving server compaction off is therefore the riskier choice**, and the risk
grows silently with time.

## Recommendation

Ship compaction **on**, scoped to the presence stream, with `TimeBasedRetention`
on a horizon of roughly **1–15 minutes** — long enough that a briefly
disconnected device catches up by ordinary delta instead of repeatedly adopting
the floor, short enough to keep any single delta well under a megabyte. Every
other stream keeps `KeepAllRetention` and is untouched.

Presence is meaningless six seconds after it is written, by design. Retaining
millions of rows of it has no product value, and the compaction floor — the
thing this update brings — is what makes a new joiner safe once the old
heartbeats are gone.
