# gossip_nearby Hardening Plan

Production log analysis and code review identified several reliability gaps. This plan covers the three highest-impact changes, plus deferred items for future consideration.

---

## Phase 1: Handshake Timeout ✅

**Problem:** When `ConnectionEstablished` fires, `ConnectionService` registers a pending handshake and sends its NodeId. If the remote side never responds (crashed, backgrounded at the wrong moment, half-open BLE link), the endpoint sits in `_pendingHandshakes` forever. The platform-level BLE connection is held open, consuming one of ~4 available BLE slots. If the same device reconnects via a new EndpointId, the duplicate detection in `completeHandshake()` won't fire because the old endpoint never completed — it doesn't have a NodeId in the registry yet. Result: zombie connection, leaked `_handshakeStartTimes` entry, reduced mesh capacity.

**Fix:** The retry timer already ticks every `_connectionTimeout` (5s). Add a sweep of `_handshakeStartTimes`: for any entry older than a handshake timeout (e.g. 10s), call `_registry.cancelPendingHandshake()`, disconnect the endpoint, and log it. The endpoint will be rediscovered and retried naturally by the existing retry mechanism.

**Status:** Complete. Handshake timeout sweep added to retry timer. Stale handshakes are disconnected and cleaned up after 10s.

---

## Phase 2: NearbyAdapter Error Handling ✅

**Problem:** `_onConnectionInitiated` does `unawaited(_nearby.acceptConnection(...))` with no error handling. If the platform rejects the accept (endpoint already disconnected, permission revoked, invalid state), no event is emitted — no `ConnectionEstablished`, no `ConnectionFailed`, nothing. The `ConnectionService` never learns the connection existed. This creates an invisible connectivity hole mid-session.

Similarly, `startAdvertising`/`startDiscovery` return `false` on failure but the adapter only checks success — failures are silent.

**Fix:**
- Wrapped `acceptConnection` in try-catch. On error, emits `ConnectionFailed` so `ConnectionService` can track the failure and retry if appropriate.
- Added logging for `startAdvertising`/`startDiscovery` failures with rethrow so the facade knows the operation failed.
- Added `reason` field to `ConnectionFailed` event for better diagnostics.
- Added try-catch-finally to `stopAdvertising`/`stopDiscovery` to always reset flags.

**Status:** Complete. Additionally, a comprehensive silent-error audit (12 findings across Critical+High severity) was completed:
- F1: Handshake send `.catchError()` with `HandshakeTimeoutError` emission + metric
- F2: Disconnect replaced endpoint `.catchError()` (log only)
- F3: `_requestConnectionSafely` added failure metric
- F4: `_onConnectionFailed` cleans up `_handshakeStartTimes`
- F8-9: Adapter stop methods use try-catch-finally, always reset flags
- F15-16: Adapter start methods rethrow after logging; facade catches without setting flag
- F17: Facade stop methods use try-finally
- F18: `disconnectAll` uses per-iteration try-catch
- F21: Retry timer `.catchError()` with re-schedule
- F23: `_handleNearbyEvent` wrapped in try-catch safety net

Design principle applied throughout: log OR emit an event, never both.

---

## Phase 3: Retry Exponential Backoff

**Problem:** `_retryPendingConnections` fires every ~5 seconds (with ±30% jitter producing 3.5–6.5s intervals) for every pending discovery, indefinitely. If an endpoint is discoverable but permanently un-connectable (Nearby Connections quota exceeded, device advertising but rejecting connections), this generates a `requestConnection` call every ~5 seconds forever — unnecessary BLE traffic and log noise. Each `requestConnection` call also temporarily stalls the Nearby Connections transport, causing SWIM probe disruption to already-connected peers.

**Fix:** Exponential backoff with ceiling. Add `retryCount` and `nextRetryAtMs` to `_PendingDiscovery`. First retry at 5s, then 10s, 20s, 40s, capped at 60s. In `_retryPendingConnections`, check `nowMs >= nextRetryAtMs` instead of a fixed age threshold. On each retry, double the interval. When `EndpointLost` fires followed by a new `EndpointDiscovered` for the same advertised name, the fresh `_PendingDiscovery` starts with a reset backoff.

**Files:**
- `lib/src/application/services/connection_service.dart` — modify `_PendingDiscovery` to track `nextRetryAtMs` and `retryCount`, update `_retryPendingConnections` logic
- `test/application/services/connection_service_test.dart` — test: retry interval doubles after each attempt; test: retry interval caps at max; test: new discovery resets backoff

**Complexity:** Low-medium

---

## Deferred Items

### Receive Pathway Shutdown
Messages continue arriving after `stopSyncing()` because BLE links outlive the stop call. Currently harmless — `NearbyMessagePort._closed` drops them. The only edge case (handshake completing during stop) is rare and recoverable. Would require a pause/resume lifecycle on `ConnectionService`, which adds complexity for little gain.

### Queue Drain on Disconnect
When a peer disconnects, queued messages for that EndpointId stay in the queue and fail one-by-one when dequeued. Correct behavior, just noisy logs. Could be cleaned up by iterating queues on disconnect and completing stale messages with errors, but `Queue` doesn't support efficient removal by predicate.

### Bounded Message Queues
With 2-5 peers, message accumulation rate (~2-4/sec) means even a 60-second stall only produces ~240 messages — not a memory concern. Revisit if scaling to dozens of peers.

### State Flag Sync (Adapter/Transport)
`NearbyTransport._isAdvertising` can desync from `NearbyAdapter._isAdvertising` if the platform call silently fails. Low practical impact — advertising failure is rare and immediately visible to the user. Partially addressed by Phase 2 (adapter now rethrows on start failure, facade catches and doesn't set flag).

### Fast-Fail on Send Error (gossip core)
`FailureDetector._safeSend` catches send errors but doesn't count them as probe failures — it waits for the full ping timeout. Treating transport errors as immediate probe failures would halve detection time for broken links. However, this lives in the `gossip` package core SWIM protocol and needs careful design to avoid false positives from transient BLE congestion. Flag for future `gossip` core enhancement.

### ConnectionRegistry Reset
No bulk-clear method. Not needed — the registry is created fresh by `NearbyTransport` factory on each start. No restart path reuses instances.
