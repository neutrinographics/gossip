# Let transports declare their frame ceiling instead of the core assuming one

**Track:** Sync engine   **Depends on:** nothing

## What this is

The library never touches a radio itself: applications plug in a
"transport" — Bluetooth, Wi-Fi Direct, a WebSocket to a server — and the
library hands it bytes to deliver. Every transport has its own limit on how
big a single delivery may be. Android's short-range networking caps a
message at about 32 kilobytes; the Bluetooth transport has its own limit
from the way it slices messages into chunks; a WebSocket to a server has no
practical limit at all.

Today only the core knows a number. It carries a single configured
message-size budget, defaulting just below the Android ceiling, and every
deployment inherits that default whether or not it is running on Android at
all. The transports — the components that actually know their own limit —
say nothing, and the explanation for "why this number" lives in the core's
documentation, far from the code the number describes.

This item moves the truth to where it lives: a transport may declare the
largest frame it can carry (or declare no limit), and the core checks its
own configured budget against whatever the local transport declares.

## Why it matters

Two things go wrong while the knowledge is misplaced.

A WebSocket deployment pays a Bluetooth-shaped tax for no reason — it is
held to a budget derived from a radio it never uses, which forces needless
splitting of data that would have crossed in one piece.

And in the other direction, a budget set larger than the local transport can
actually deliver produces the worst kind of failure: messages that are built,
handed over, and then quietly fail to arrive, with no obvious cause. Making
the transport state its ceiling turns that into an error at startup, said out
loud, instead of a mystery in the field.

## Rough approach

Give the transport interface an optional "largest frame I can carry"
capability, where absent means unbounded, and have each transport answer with
its own truth. Keep the core's configured budget as what it has always
been — the agreement the whole mesh shares, since the real constraint is the
weakest link somewhere out in the network, which no single node can observe
locally. On startup, compare the two: if the mesh-wide agreement exceeds what
the local transport can carry, fail loudly rather than discovering it one
undelivered message at a time.

The documentation explaining each ceiling moves into the transport that owns
it, leaving the core to explain only the mesh-wide agreement.

## Related

- Sibling transport-contract convergence:
  [Converge the transports' MessagePort close() semantics](health-transport-port-close-semantics.md)
  — same theme of the port contract being drawn in different places by
  different transports.
- The Kotlin twin has the same shape of question, and its budgeting work is
  scoped in
  [The Dart↔Kotlin wire-versioning campaign](kt-wire-versioning-campaign.md).
