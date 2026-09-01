# Sweep the remaining minor audit findings

**Track:** Code health   **Depends on:** nothing

## What this is

The catch-all closing round ("R14") of the 2026-07-08 audit — everything
small that remains open, enumerated here so nothing hides behind a label.

**Two latent correctness bugs** (small, but real bugs waiting on
unlucky inputs):

- **Unbudgeted sync-request size (COR3-28).** The "what I already have"
  summary sent when requesting missing data is an unbounded list; a node
  whose summary for one stream outgrows the message size limit can
  advertise that stream but never pull it — a permanent, silent stall.
  Bound it the same way the digests were.
- **Payloads are held by reference, not copied (COR3-30).** An application
  that reuses a scratch buffer after appending can corrupt what gets
  stored and synced — and because entry equality ignores payload bytes,
  local and remote copies can differ silently. Copy at the public API
  boundary.
- **`appendAll` registers a phantom empty stream on a rejected batch.**
  `getOrPut` creates the stream-map entry before the batch is validated,
  so a batch rejected in full still leaves behind an empty stream — a
  stream that reads as having been written when it never was. Surfaced by
  the Kotlin port's Batch KT-B review, which found the identical shape on
  the Dart side and fixed it on the Kotlin side (`fb0cd32`); see the
  [twin-divergence register](kt-normalize-twin-divergences.md)'s
  `appendAll` phantom-stream row. Validate before the `getOrPut`, same fix
  shape.
- **A first-cycle `nextDelay` throw escapes `GenerationScheduler.start()`
  synchronously.** The scheduler calls `nextDelay()` as the argument to
  `timePort.delay(...)`, so on the first cycle a throwing `nextDelay`
  propagates out of `start()` while on every later cycle the same throw
  reaches `onSchedulingError` — one defect, two failure surfaces. Surfaced
  by the Kotlin port's Batch KT-C review, whose port calls `nextDelay()`
  inside the loop's own error handling and is uniform; see the
  [twin-divergence register](kt-normalize-twin-divergences.md)'s
  `nextDelay` error-uniformity row. Move the call inside the scheduled
  chain, same shape as the Kotlin side.

**Transport behavior minors** (each small; none has another home):

- Silent code paths in the BLE transport that swallow outcomes without a
  log conduit (MIN-14), and its pending-send count excluding the message
  currently in flight (MIN-15).
- Maps keyed by radio address that grow without pruning under iOS address
  rotation (MIN-17).
- The Nearby transport's robustness edges: an unguarded parse of the
  peer's advertised name can throw on hostile input (MIN-18), and it has
  no reconnect/backoff/adapter-state handling at all (MIN-19).
- The BLE send queue's remaining halves of MIN-16 (per-lane aging and
  queue metrics; the depth ceiling itself is
  [its own item](engine-send-queue-depth-cap.md)).
- Per-channel cleanup for the sync engine's per-peer bookkeeping: removing
  a channel clears neither the merger's reported-gap dedup nor the
  stalled-range registry (2026-09-01 branch review, finding 6) — both
  linger until peer removal or `stop()`, an unbounded-in-principle map in
  long-lived processes with ephemeral channels. Fix both with one
  clear-for-channel seam.

**Hygiene** (the rest of the MIN-series and actionable observations):
dead types and phantom events (MIN-4/5/6/7, OBS-9's vestigial API),
retention-policy input validation, safe parsing (`tryParse`),
documentation drift, unused dependencies, persistence-call multiplicity
for pluggable stores (MIN-10/OBS-6), and naming normalization across the
transports (OBS-7). A reusable `EntryRepository` conformance suite
(restart-survival of high-water marks and compaction floors across a
process restart) is where COR3-8's guarantee ultimately lives for a
persistent implementation — there's only the in-memory one today, so
"restart" is moot until one exists; future work when it does.

**Wire-scheduling audit minors (the 2026-08 audit's R9 tail):** the
remaining small findings WIRE4-16, -17, -18, -21, -22, -24, -26, -28,
and -30 through -36 — each graded small in that audit's recommendations
table; sweep them the same way (the doc-drift half of -34 was already
fixed with the pacing work; -19 piggybacking grew into
[its own item](engine-digest-on-probe-piggyback.md)).

**Docs links pass:** rename the bounded-context ADR file
(`010-ddd-layered-architecture.md`) to match its rewritten title and
update every inbound link (GLOSSARY, backlog files, specs) in one sweep.

## Why it matters

Individually small; collectively they are the gap between "audited" and
"clean". The two latents above deserve to be fixed first — they are
bugs, not polish.

## Related

- Findings COR3-28, COR3-30, and the MIN-/OBS-series in
  [audits/2026-07-08-comprehensive-audit.md](../audits/2026-07-08-comprehensive-audit.md).
- **OBS-3 (the responder's digest fitting never rotated) shipped** — the
  responder path now has its own rotation cursor, independent of the
  requester's, so an over-budget response covers every stream across
  successive exchanges instead of truncating the same tail forever.
- SWIM probe-timing observations (OBS-4/OBS-5) live with
  [the failure-detection threshold item](engine-swim-threshold-tuning.md).
- Test-port production-fidelity (MIN-13) lives with
  [the harness quality-of-life item](testing-harness-niceties.md).
- [One Bluetooth link per device pair in a mesh](engine-mesh-connection-tiebreak.md)
  — the tie-break/star documentation drift named by the audit was fixed
  with that item.
