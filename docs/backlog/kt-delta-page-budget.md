# Page delta responses to the byte budget in the Kotlin library

**Track:** Kotlin port   **Depends on:** nothing   **Done:** 2026-11-28, gossip-kt PR #26

## What this is

When one device asks another for the entries it is missing, the answer has
to travel in frames the transport can carry — 30 KB on a phone. The Dart
library answers in pages: it fills one frame with as many entries as fit, in
order, marks the page as partial, and the asking device immediately asks for
the next page until it has caught up. An entry too large to ever fit in a
frame is reported as an error and set aside so it cannot hold up the other
authors in the same stream.

The Kotlin library sends the whole answer in one frame, however large. A
phone that has been away for a week and comes back to a busy stream asks the
server for everything it missed and is answered with a frame far larger than
its transport will accept. The server's reactive push of a burst of fresh
writes has the same shape: one frame, no size check.

This item gives the Kotlin library the same paging rule as Dart, the same
error for an entry that can never fit, and the same skip for a push frame
that is too big (its entries are simply delivered by the next round's paged
answer instead).

## Why it matters

A device that falls far behind is exactly the one that most needs to catch
up, and today it is the one the server answers with a frame it cannot
receive. Found by reading the code on 2026-11-27, not yet reproduced live;
the shape is a long absence followed by a reconnect. The receiving half —
asking for the next page when one is marked partial — already exists on both
libraries, so this is the missing sender half.

## Rough approach

Mirror Dart one for one, in the Kotlin library's own shape: the paging rule
as a pure domain service (what goes in a page, what is set aside, when a
page is partial), and a small application class that measures frames
through the wire codec and feeds the rule — the same split the digest budget
already uses. Port every Dart test that pins the behaviour, and add one
end-to-end scenario that drains a many-page backlog over the in-memory
network.

## Related

- Design: [2026-11-27 delta page budget design](https://github.com/neutrinographics/gossip-kt/blob/main/docs/superpowers/specs/2026-11-27-kt-delta-page-budget-design.md)
  (in the gossip-kt repository).
- Re-homed from [Port the wire-efficiency behaviors to the Kotlin library](kt-port-wire-efficiency.md),
  whose phase 2 parked the page cut and closed without it.
- Register rows "Pull planning's name" and "A pull for a stream the
  responder does not hold" in
  [the twin-divergence register](kt-normalize-twin-divergences.md) close
  with this item.
- The per-entry cap that keeps a single entry under the frame size on both
  sides: [Give the Kotlin library the payload size cap the Dart library enforces](kt-payload-size-cap.md).
- Splitting a single oversized payload across frames is a different idea:
  [engine-large-payload-chunking](engine-large-payload-chunking.md).
