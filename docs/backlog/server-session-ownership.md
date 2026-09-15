# Stop the server from talking to a phone's dead session after it reconnects

**Track:** Server   **Depends on:** nothing

## What this is

When a phone's connection to the server drops and the phone reconnects,
the server briefly has two handlers for the same device: the old one
finishing its cleanup and the new one just registered. The old handler's
cleanup removes the device by identity without checking that the session
it is tearing down is still its own, so it unregisters the *new* session
and removes the peer the new session just added. The server then keeps
addressing a session that no longer exists, and every send logs a warning
about a missing session until something re-registers the device.

## Why it matters

Phones sleep, wake, and change networks constantly during a meeting. In
the 2026-09-15 meeting the server logged 267 sends to a departed peer
across ten devices, 193 of them for one phone that reconnected twelve
times. Each is a gossip round, push, or probe wasted on a dead socket, and
while it lasts that phone is not being synced by the server at all.
Production logs had already shown sends to departed peers continuing for
minutes or hours before the health line existed.

## Rough approach

Give each registration a token. Unregister and remove the peer only if the
token still matches the session doing the cleanup; otherwise the newer
session has taken over and the old handler leaves it alone. One test that
opens two sessions for one device in quick succession and asserts the
second survives the first's cleanup. Extract the session lifecycle into a
small application service so the route handler stays thin. Best shipped
together with
[Let compaction prune presence while a meeting is running](server-compaction-under-load.md)
as one server release, validated on a live device through the tunnel
runbook.

## Related

- Design and rulings (for the owner's review): opendoor-api
  `docs/superpowers/specs/2026-09-15-meeting-server-fixes-design.md`.
- Measured in [the 2026-09-15 meeting report](../audits/2026-09-15-production-meeting-measurement.md), finding F2.
- The library-side counterpart of stopping cleanly shipped in the
  receive-loop lifecycle batch:
  [Make stopping a Kotlin coordinator actually stop it](kt-coordinator-restart-lifecycle.md).
