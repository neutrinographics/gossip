# Make stream access get-or-create in the Kotlin library

**Track:** Kotlin port   **Depends on:** nothing

## What this is

In the Dart library, asking a channel for a stream that doesn't exist yet
quietly creates it — "get or create" — so two devices that each start writing
to the same stream name converge without ceremony. The Kotlin library's
equivalent path does not create; the divergence register records this as a
real production issue, and the Kotlin test harness currently works around it
rather than relying on it.

(The channel level was already fixed: creating a channel that exists returns
it. This item is the stream-level half of the same contract.)

## Why it matters

The two libraries disagree about a basic write-path contract. Application
code written against the Dart behavior — write first, let the stream appear —
fails or misbehaves when the same logic runs on the server. Contract
divergences of this kind are exactly what the parity program exists to
eliminate: they surface as "works on the phone, breaks on the server" bugs
that are miserable to trace.

## Rough approach

Port the Dart get-or-create semantics at the stream access path, with the
same defaulting the Dart side applies (retention defaults live in the
service, not the aggregate). Remove the harness workaround so the tests rely
on the contract they are supposed to pin.

## Related

- Recorded (previously unhomed) in the
  [divergence register](kt-normalize-twin-divergences.md), row
  "`getOrCreateStream` is not get-or-create in kt".
- Homed by the 2026-09-01 parity survey; see the
  [twin parity program](../parity.md).
