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

## Related

- Raised by the [algorithm audit](../audits/2026-07-06-algorithm-audit.md)
  (finding H3), alongside the already-shipped fair-rotation probing.
