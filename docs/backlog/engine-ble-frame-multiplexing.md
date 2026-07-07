# Eliminate head-of-line blocking on the Bluetooth transport

**Track:** Sync engine   **Depends on:** nothing

## What this is

When two devices are connected over Bluetooth Low Energy, everything they
send each other travels down a single slow pipe, one message at a time. A
large message (a batch of synced data) can therefore hold up a small, urgent
one queued behind it.

The system already handles part of this: urgent messages (the periodic
"are you still there?" health checks) are allowed to jump ahead of large
messages that are still *waiting* to be sent. What it can't yet do is
interrupt a large message that is *already partway* down the pipe. So a
health check can still wait out the tail of one in-progress transfer.

This item is about removing that last bit of waiting — letting an urgent
message interleave with a large one already in flight, so it is never delayed.

## Why it matters

Bluetooth Low Energy is slow — only a few kilobytes per second. A single
large transfer can occupy the link for several seconds. During that window,
the health checks that tell one device whether the other is still alive can
be delayed enough to look like a failure, causing a perfectly healthy device
to be wrongly dropped from the group. Closing this gap makes failure
detection dependable even in the middle of a big transfer.

## Rough approach

Change the low-level "framing" — how a message is split into pieces for the
wire — so pieces from two different messages can be tagged and sent
interleaved, with the receiver reassembling both at once. Today each message
must be sent as one unbroken run of bytes, which is what forces the waiting.
This is a change to the chunking/reassembly format on both the sending and
receiving sides.

## Related

- A partial mitigation already shipped: an urgent-vs-normal priority send
  queue that bounds an urgent message's wait to at most one in-flight
  transfer. See the [algorithm audit](../audits/2026-07-06-algorithm-audit.md)
  (finding H1).
- Sibling: [Bound the Bluetooth send-queue depth](engine-send-queue-depth-cap.md).
