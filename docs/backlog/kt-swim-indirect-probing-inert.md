# Make the Kotlin library's indirect health probing actually work

**Track:** Kotlin port   **Depends on:** nothing

## What this is

Devices in a mesh keep track of which of their neighbours are still alive.
The usual way is to ping a neighbour and wait for a reply. But a single
missed reply is weak evidence — the radio may simply have been busy — so
the protocol has a second, cleverer step: before writing a neighbour off,
a device asks a *third* device to try pinging it on its behalf. If the
relay gets an answer, the neighbour is fine and the first device just
couldn't reach it directly. This is called indirect probing, and it is what
stops a one-way radio problem from being mistaken for a dead device.

In the Kotlin library this second step is present in the code but never
succeeds. The relay device is asked to probe, it sends the ping, and then
it waits for the answer — but it waits in a way that blocks the very queue
the answer has to arrive through. So the answer can never be processed
while the relay is waiting for it. The relay always times out, never
reports back, and by the time the late answer could be matched up, the
record it belonged to has already been discarded.

The Dart library does not have this problem: it processes incoming
messages in a way that does not block while a handler waits, and it uses
two independent subscriptions rather than one shared one.

## Why it matters

Indirect probing is the part of the protocol that distinguishes "this
device is gone" from "I personally can't reach this device right now."
With it inert, the Kotlin library falls back to direct evidence alone, so
a device with a one-way radio fault gets marked suspect — and eventually
unreachable — even when a healthy relay sitting between the two could have
confirmed it was alive the whole time. Every device that is merely hard to
reach from one direction looks dead from that direction.

It also means the two libraries genuinely disagree about the health of the
same network, which matters because they are meant to be two halves of one
system: the same one-way-deaf pair keeps both views healthy on the Dart
side and degrades on the Kotlin side.

## Rough approach

The fix is not a one-liner, which is why it wants its own task rather than
riding along inside another change. The obvious move — handling each
incoming message concurrently so nothing blocks the queue — is unsafe as-is:
the health detector keeps a couple of pieces of bookkeeping in plain
unguarded fields that are already touched from two different places, so
adding a third concurrent path needs those guarded first. The single-queue
design is also deliberate and documented elsewhere in the library, because
another component relies on it to avoid its own synchronisation. So the
work is: decide whether to make the health detector's message handling
concurrent (and guard its state), or to let the relay wait without holding
the queue — then prove it with the scenario that cannot pass today.

There is a ready-made acceptance test waiting: one scenario in the Dart
suite (a one-way-deaf pair with a healthy relay keeping both views
reachable) has no Kotlin translation precisely because of this defect.
Translating it is the proof the fix works.

## Related

- Recorded with the full mechanism, file-level evidence, and the
  behavioural consequence in the twin-divergence register:
  [Record where the Dart library and its Kotlin twin diverge, with a verdict](kt-normalize-twin-divergences.md).
- Found during the correctness-and-scenarios batch of
  [Teach both libraries to speak versioned wire formats](kt-wire-versioning-campaign.md).
- Sibling: [Sweep the remaining scenario coverage into the Kotlin library](kt-scenario-parity-sweep.md).
