# Close the recorded test debt from the tie-break/rejection reviews

**Track:** Testing   **Depends on:** nothing

## What this is

The BLE tie-break and rejection-frame work shipped with a clean final
review, but the review deliberately recorded a short list of small,
non-blocking gaps rather than holding the merge for them:

- The design spec names a "queued-send behavior across a tie-break link
  swap" test that was verified by code-reading but never written: messages
  queued behind an in-flight send must fail cleanly or re-route to the
  surviving link when the registration swaps mid-stream.
- The backoff de-duplication branch (a rejection reported by both the
  connect call's exception and the error stream in one cycle must compound
  only once) is logically sound but untested.
- The mutual-connect end-to-end test staggers the race in one order only;
  the spec asked for both. Related: no end-to-end case drives a mutual
  connect through the auto-connect policy (bypassed by design because its
  dedup suppresses the race — worth one case if auto-connect routing ever
  changes).
- Two codec edge tests: parsing a control frame from a non-zero-offset
  byte view, and "capacity-rejecting a central sends no frame".
- One open product decision: after a peer that repeatedly rejected us
  finally accepts a connection, should its escalated backoff memory reset
  (fresh 1s ramp on the next rejection epoch) or persist (current
  behavior — up to 60s on the first rejection after a recovery)? Current
  behavior errs safe; decide and pin with a test.

## Why it matters

Each item is a place where behavior is correct today but unpinned — the
next refactor of the connection manager or auto-connect policy could
regress one silently. Small, mechanical, and all the fixtures already
exist.

## Related

- Shipped work these tests harden:
  [One Bluetooth link per device pair in a mesh](engine-mesh-connection-tiebreak.md),
  [Tell a rejected Bluetooth peer it was rejected](engine-reject-notify-capped-peers.md).
- Spec: [the design doc](../superpowers/specs/2026-07-10-bluey-tiebreak-rejection-design.md).
