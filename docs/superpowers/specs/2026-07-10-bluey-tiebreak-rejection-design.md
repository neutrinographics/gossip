# bluey: post-connect mesh tie-break + rejection control frame

**Status:** approved 2026-07-10 · **Findings:** COR3-29, COR3-21 (2026-07-08 comprehensive audit)
**Scope:** `packages/gossip_bluey` only, plus doc corrections in the root `CLAUDE.md`.

## Problem

1. **COR3-29 — duplicate physical links in a mesh.** In a mesh every device
   both advertises and scans, so two devices routinely connect to each other
   simultaneously. Each side keeps its own central link and "rejects" the
   inbound peripheral one — but bluey has no peripheral-side disconnect, so
   the rejected link stays physically up. Every mutual connect holds TWO GATT
   links. At the recommended 8-device scale that approaches double the
   platform connection ceilings, invisibly (the registry reports the deduped
   count).
2. **COR3-21 — capped-out peers gossip into the void.** When a device at
   `maxConnections` rejects an inbound peripheral link, the remote central is
   never told: its writes are acked at GATT level and dropped above. It
   believes the link is healthy indefinitely, wasting a connection slot and
   radio on both sides.
3. **Doc drift.** The root `CLAUDE.md` claims a pre-connect tie-break by
   `NodeId` in the advertisement and a `startDiscovery(filter: hubId)` star
   filter. Neither exists.

## Rejected premise (recorded for posterity)

A pre-connect tie-break via identity in the BLE advertisement is not reliably
possible cross-platform: iOS peripherals cannot advertise manufacturer data
(`Capabilities.canAdvertiseManufacturerData == false` in bluey; Android:
true), and backgrounded iOS demotes even service UUIDs to the overflow area.
Best-effort advertisement hashing (Android↔Android fast path) is **explicitly
deferred** — it would only shorten the transient double-connect, which the
design below already bounds to one identify round-trip.

## Design 1: post-connect tie-break — the loser closes its own central link

**Rule.** For any pair, the surviving link is the one where the
**lexicographically smaller `NodeId.value` is the central** ("the smaller ID
initiates"). Both sides compute this independently from (localNode, remote
NodeId) and always agree.

**Key topology fact** that makes this work with no peripheral-disconnect API:
in a mutual connect the two physical links are A-central→B-peripheral and
B-central→A-peripheral. Each side's redundant *central* link — which it CAN
close — is the other side's peripheral link. When the tie-break loser closes
its own central, exactly one physical link remains.

**Where:** `ConnectionManager`'s duplicate-detection path (today:
`registry.contains(nodeId)` → role-guarded rejection of the newer link).
Replace role-based "newest loses" with the tie-break. Four arrival cases on a
device with local ID `L`, remote `R` (`L wins` = `L < R`):

| # | Registered link | New link | Outcome |
|---|---|---|---|
| 1 | central | peripheral arrives | **L wins:** keep central; decline to register the peripheral (as today). The remote — the loser — physically closes that link from its end (it is the remote's central). |
| 2 | central | peripheral arrives | **L loses:** close own central (`port.disconnectRole(central)`), register the peripheral link as the active handle (fresh `FrameDecoder`, `PeerClosed`+`PeerOpened` or an in-place handle swap — implementer's choice, but byte-stream alignment must reset with the link). |
| 3 | peripheral | own `connectTo` completes late | **L wins:** register the new central as active; the stale peripheral registration is superseded via the existing COR3-5 supersession machinery (stale-link events are already no-ops). The remote closes its central from its side. |
| 4 | peripheral | own `connectTo` completes late | **L loses:** close the just-established central immediately; keep the peripheral registration untouched. |

**Contract changes.**
- `connectTo(nodeId)` returns normally when the peer ends registered via
  *either* link (a lost tie-break with a surviving peripheral link is a
  SUCCESSFUL connect); it throws `ConnectionRejectedException` only when the
  peer ends not-connected.
- `AutoConnectPolicy` is unchanged: after resolution the peer is in the
  registry, so the existing dedup check suppresses reconnect churn.
- Send queues: an in-flight send on a link closed by tie-break aborts via the
  existing per-chunk `identical(registry.get, handle)` check; queued messages
  re-route to the surviving handle if registration was swapped in place, else
  fail cleanly (same semantics as today's disconnect path). The message-level
  outcome must match the `MessagePort` contract: known failure → error-completed
  future.

**Accepted residual:** the transient double-connect (both links physically up
until identity resolves, ~one identify round-trip). Deterministic tests must
assert convergence to exactly ONE physical link, not that two never existed.

## Design 2: rejection control frame (GSP2)

**Wire format.** Data frames stay `GSP1`, byte-for-byte unchanged. Control
frames use a new magic `GSP2`:

```
"GSP2" (4 bytes) · length u32 (payload length, big-endian, matching GSP1) ·
payload: type u8 · type-specific bytes
```

- type `0x01` = CONNECTION_REJECTED, payload continues with reason `u8`:
  `0x01` = at capacity. Unknown types/reasons are logged and ignored.
- **Version-skew safety:** an old decoder treats a `GSP2` frame as garbage and
  scan-recovers to the next `GSP1` magic (existing, tested recovery path). So
  new→old rejection frames are harmlessly ignored — behavior identical to
  today. No negotiation, no flag day.

**Sender.** In the `maxConnections` rejection branch for an inbound
peripheral link: encode and send CONNECTION_REJECTED(capacity) on the
still-live link (outbound writes on a rejected peripheral link work), then
mark the link rejected exactly as today. Best-effort single shot: a send
failure is logged and the flow continues (no worse than current behavior).
Duplicate rejections do NOT send a frame — the tie-break makes those
self-resolving.

**Receiver.** `ConnectionManager` dispatches on the frame magic before the
protocol codec sees bytes. On CONNECTION_REJECTED for a link where we are
central: close our own central link, emit `PeerClosed` with a distinct
rejected-by-peer reason, record a failure with `AutoConnectPolicy`'s existing
per-NodeId backoff (capacity is retryable — a slot may free up), and emit a
typed `ConnectionError` (new `ConnectionRejectedByPeerError`) on the errors
stream so applications can observe it. A rejection frame on a link where we
are NOT central (malformed/spoofed situation) is logged and ignored.

## Design 3: documentation corrections

- Root `CLAUDE.md`: replace "Tie-break by `NodeId.value` ensures one
  initiator per pair" (pre-connect, false) with the post-connect rule above;
  replace "spokes call `startDiscovery(filter: hubId)`" with the truth — star
  topology holds by construction because only the hub advertises, so spokes
  can only discover the hub. No filter parameter exists or is added.
- Mirror the same corrections wherever gossip_bluey's own README/spec echoes
  them.
- Roadmap: mark `engine-mesh-connection-tiebreak` and
  `engine-reject-notify-capped-peers` done on completion; note the deferred
  best-effort advertisement optimization inside the tie-break backlog file's
  Related section (idea only, no priority).

## Testing (strict TDD, red first where behavior changes)

**Unit — `ConnectionManager`:** all four arrival cases × both tie
directions; `connectTo` returns success on a lost-tie-break-with-surviving-
peripheral; queued-send behavior across a tie-break link swap; rejection
sender fires only on the capacity branch; receiver closes/backs-off/emits on
CONNECTION_REJECTED; non-central receiver ignores it.

**Unit — codec:** GSP2 encode/decode round-trip; unknown type/reason
ignored; GSP2 bytes fed to the existing GSP1 decoder are skipped via garbage
recovery with a following GSP1 frame intact (mixed-version safety).

**End-to-end (FakeBlueyPort + real Coordinator, extending the adverse-link
harness):**
1. Simultaneous mutual connect → converges to exactly ONE physical link
   (assert on the fake's real link count — the metric COR3-29 says is
   invisible today), gossip syncs afterward, and the surviving link's central
   is the smaller NodeId.
2. Same, with the `connectTo` completions racing the inbound links in both
   orders (covers cases 3/4).
3. Capacity rejection: a full device + newcomer → newcomer receives the
   frame, closes its link (fake link count drops), enters backoff (attempt
   count pinned), and NO gossip flows into the void; after the full device
   frees a slot and the newcomer retries, sync completes.
4. Mixed-version: rejection frame delivered to a receiver without GSP2
   support is skipped harmlessly and a subsequent data frame still decodes.

**Gates:** `flutter test` green in gossip_bluey, `dart analyze` clean, no
production changes outside `packages/gossip_bluey/lib` + docs.

## Out of scope

- Best-effort advertisement hash (Approach B) — deferred, recorded above.
- bluey-library changes (no per-client peripheral disconnect API is added).
- gossip_nearby (its rejection story is different and its cap handling
  already disconnects properly).
