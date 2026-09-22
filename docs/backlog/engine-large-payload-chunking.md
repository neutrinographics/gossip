# Carry a payload bigger than one message, in pieces

**Track:** Sync engine   **Depends on:** nothing today; only worth starting when a feature needs entries larger than the payload cap

## What this is

Every entry has to fit inside one sync message, because a message has to fit
the transport's frame budget and the library moves whole entries. So there
is a hard ceiling on how big one entry's payload can be: about 7.5 KB on
the wire dialect the fleet runs today, about 22 KB once the fleet moves to
the newer one. An application that wants to store something bigger has to
split it up itself. This item is about the library doing that splitting and
reassembling for the application, so a large payload goes in as one write
and comes out as one read.

## Why it matters

Today the app keeps every payload small by design: it bounds free text at
the input, and it keeps big things such as lesson media out of the log
entirely, referencing them by id. That is the right design for blobs and
nothing needs more. But a future feature that wants a large record in the
log — a long-form document authored on a device, say — would hit the
ceiling, and the only answer would be app-level chunking written for that
feature alone.

## Rough approach

Two shapes, very different in cost; the first is the one to build if the
need arrives.

- **A chunking helper the application opts into.** A small codec that
  splits a payload into pieces at write time, each piece an ordinary entry
  with a tiny header (which whole it belongs to, its index, the count),
  and reassembles the whole in the application's materializer before it
  folds. Nothing in the sync engine or on the wire changes: pieces are
  plain entries, so pagination, the contiguity guard, compaction and both
  twins handle them already, and the app's own event envelope carries the
  version an older build needs to know it cannot read them. A few days,
  shippable without touching the fleet.
- **Transparent fragmentation inside the library.** The engine hides the
  pieces from the application. Every part of the core that reasons about
  entries has to learn that some entries are halves of something: the fold
  path needs a reassembly buffer and a cursor that can rest on an
  incomplete logical entry while other authors' entries sort between its
  pieces; retention and compaction have to prune all pieces or none; the
  wire needs a field that marks a fragment, which an old build would fold
  as a whole entry and decode as garbage, so it is a dialect change with a
  fleet capability gate; both twins, the conformance vectors and the app's
  protocol translator move together. Weeks, with rulings, and the riskiest
  change since compaction. Only justified if several features need large
  entries and the application-level seam has become a burden.

## Related

- The ceiling itself: [give the Kotlin library the payload size cap the Dart library enforces](kt-payload-size-cap.md) (the Dart cap shipped in the wire batch; the arithmetic is in the [wire versioning spec](../superpowers/specs/2026-08-28-wire-versioning.md)).
- The free tripling of the ceiling: the v2 send flip on the roadmap's focus list.
- How the app stays under the cap today: OpenDoorApp bounds a lesson response at 7,000 encoded bytes against the 7,552 cap and catches the library's refusal as a validation failure.
