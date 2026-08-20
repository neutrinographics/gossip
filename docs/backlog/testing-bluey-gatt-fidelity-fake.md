# Make the Bluetooth test fake faithful to real GATT behavior

**Track:** Testing   **Depends on:** nothing

## What this is

The Bluetooth transport's tests replace the platform-facing layer with a
simple fake network: if two devices are connected, bytes sent are bytes
delivered. Real Bluetooth is subtler in ways that matter:

- a receiver only gets a notification if it has already *subscribed* to it;
- the two ends of a new connection become ready at different moments — one
  side can believe the link is up while the other is still finishing setup;
- the size of each write is negotiated per link, and is far smaller (20
  bytes) when nobody negotiates;
- the identity exchange rides on a heartbeat with its own timing.

None of that is modeled today, and the adapter code that deals with those
realities is exactly the code the fake replaces — so it runs under no test
at all.

Two increments:

1. **Subscription state in the existing fake** (small): data sent before the
   receiver has subscribed is silently lost while the sender still sees
   success — which is real Bluetooth behavior — with a configurable delay
   between "connected" and "subscribed". Also default the fake's per-write
   size to the 20 bytes an un-negotiated Android link actually gets, so
   every existing test runs at realistic chunking pressure.
2. **A fake of the Bluetooth library's own API surface** (the real item):
   scanner, GATT server, and peer connection, faithful to
   subscribe-before-notify, connection-setup ordering (including the
   identifying heartbeat), and per-link write-size negotiation — so the
   platform adapter itself finally executes under test.

## Why it matters

The 2026-08 wire-scheduling audit found a shipped fix — telling a rejected
peer it was rejected — that passed every test yet very likely never works on
real hardware: the notice is sent before the other side has subscribed, so
the real platform drops it while the fake delivered it (finding WIRE4-9).
All three of that audit's top transport findings (radio duty cycling,
write-size negotiation, the rejection race) live in the layer no fake
touches. Until the fake is faithful, this whole class of bug is invisible
until someone tests on physical devices. Increment 1 is also the
prerequisite for test-driving the WIRE4-9 fix itself.

Real-hardware smoke tests remain the final word for platform quirks; they
are complementary and out of scope here.

## Rough approach

Increment 1 is a small change to the existing fake plus regression tests for
the notify-before-subscribe loss. Increment 2 introduces a fake beneath the
platform adapter so the adapter's connection registration, identification,
and send paths run in tests; grow its fidelity scenario-by-scenario (the
scenarios the audit names first) rather than aiming for a full Bluetooth
simulator.

## Related

- Motivated by findings WIRE4-7/8/9 in
  [audits/2026-08-20-wire-scheduling-audit.md](../audits/2026-08-20-wire-scheduling-audit.md).
- Deepens the suite from
  [testing-bluey-adverse-e2e.md](testing-bluey-adverse-e2e.md) — that fake
  models the transport's port interface; this item models the Bluetooth
  layer beneath the adapter.
- Would verify the delivery mechanism of
  [engine-reject-notify-capped-peers.md](engine-reject-notify-capped-peers.md)
  (the WIRE4-9 race).
- Sibling test-infrastructure knobs:
  [testing-harness-niceties.md](testing-harness-niceties.md).
- The existing fake: `packages/gossip_bluey/test/fakes/fake_bluey_port.dart`;
  the untested adapter:
  `packages/gossip_bluey/lib/src/infrastructure/adapters/bluey_port_impl.dart`.
