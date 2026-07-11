# Revisit the failure-detection sensitivity thresholds

**Track:** Sync engine   **Depends on:** nothing

## What this is

The system decides a nearby device has gone offline after it misses a run of
consecutive health checks. Today it takes five misses to mark a device as
"suspected" and fifteen to give up on it entirely. This item is about
re-examining whether those numbers are still the right ones, now that other
safeguards are in place, to potentially notice real failures faster without
raising more false alarms.

## Why it matters

There's a genuine trade-off. Higher thresholds are slower to notice a device
that has actually died; lower ones risk wrongly dropping a healthy device
that was merely slow for a moment. The current values were chosen to be
cautious because Bluetooth latency swings a lot. Since then several
robustness improvements have landed — the system now checks each device on a
fair rotation, adapts its timeouts to each link's real speed, and can confirm
a device through a third device before giving up. Those may leave room to
tighten the thresholds for faster detection. It needs to be settled with
measurement, not guesswork.

## Rough approach

Measure, on real Bluetooth hardware, how long detection currently takes and
how often it false-alarms at the present thresholds, then try lower values
and compare. It's a tuning experiment with no structural change to how
detection works.

## Scope note

Three related observations belong to this item's measurement pass:

- Contact times are recorded when a probe is *sent* rather than when it
  succeeds (audit OBS-4).
- Sequential probe phases plus orphaned timeout timers can add several
  timeout-lengths to a round's cadence, which matters most in two-device
  meshes (audit OBS-5).
- A send that the transport *reports failed* still waits out the full
  ping timeout before counting as a missed probe — treating a hard
  transport error as an immediate probe failure would roughly halve
  detection time for broken links. Needs care to avoid false positives
  from transient radio congestion (flagged in the Nearby package's
  hardening notes as a future core enhancement).

All three affect how the thresholds behave in practice, so tune them
together.

## Related

- Raised by the [algorithm audit](../audits/2026-07-06-algorithm-audit.md)
  (finding H3), alongside the already-shipped fair-rotation probing.
