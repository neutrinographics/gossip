# Only tell a peer about the groups you both belong to

**Track:** Sync engine   **Depends on:** nothing

## What this is

When two devices meet, each one sends the other a summary of everything it
has, so they can work out who needs what. Today that summary covers *every*
group the device belongs to — plus the device owner's own personal channel,
which by design nobody else ever holds.

The receiving device has no use for almost any of it. It looks up each group
in turn, finds it holds none of them, and discards the entry. Meanwhile the
one group the two devices genuinely share is handled correctly, and syncs
fine. The waste is entirely in the extras.

Observed live on a phone and a tablet that shared a single group: the phone
belonged to eighteen other groups and announced all of them, along with its
owner's personal channel — nineteen entries the tablet could do nothing
with, repeated on every exchange. Over a few minutes that came to more than
four hundred discarded entries, at roughly six kilobytes per exchange
against sixty-three bytes when the same device had nothing to say.

## Why it matters

Three separate costs, in increasing order of seriousness.

**Battery and airtime.** The summary is sent on every meeting, and these
devices meet constantly. Sending several kilobytes to describe groups the
other side cannot use is pure overhead on exactly the constrained radio
links this library exists to serve — and it grows with how many groups a
person belongs to, so the most active users pay the most.

**Noise that hides real problems.** Each discarded entry is logged. A device
that is working perfectly produces hundreds of "I do not know this group"
lines, which is the kind of routine noise that trains people to ignore logs
and buries the messages that do matter.

**Information disclosed to strangers.** This is the part worth taking
seriously. Any device within radio range learns the identifiers of every
group the sender belongs to, and the identifier of the sender's personal
channel — regardless of whether the two have any relationship. It is
identifiers rather than the content of anyone's messages, so the exposure is
mild, but it is real: it tells a bystander that a given account exists, that
it is active nearby, and roughly how many groups it participates in. Nothing
in the design intends that, which is usually a sign it should be closed
before it becomes something someone relies on.

## Rough approach

The receiving side already knows which groups it holds, so the cheapest
version costs nothing on the wire: the summary can be filtered down to
groups the peer has previously shown interest in, learned from what that
peer has asked for or offered before. That helps steady-state traffic but
not a first meeting.

A more complete fix has each side state what it is interested in, so the
other can answer narrowly. That is a protocol change and needs care — a peer
should not be able to learn group identifiers simply by claiming interest in
everything, which is close to the disclosure problem this item is trying to
solve. Comparing summaries of the group lists, rather than the lists
themselves, is the usual way out and is worth exploring before committing to
a design.

The personal channel is a simpler and separable case: it is never shared
with anyone by definition, so it can be excluded from the summary outright
without any protocol negotiation. That alone is a small change and worth
doing on its own if the larger question stalls.

## Related

- [Send reactive pushes only to peers that share the data](engine-push-scoping.md)
  — the closest sibling: the same "does this peer share the data?" question,
  asked of unsolicited pushes rather than of the summary exchange. Whichever
  is built first should produce a membership notion the other can reuse.
- [Piggyback sync summaries on liveness probes](engine-digest-on-probe-piggyback.md)
  — also concerned with what the summary costs to send, from the other
  direction: how often it goes out rather than how large it is.
- [Cut redundant work on the message hot path](engine-hot-path-performance.md)
  — sibling efficiency work on the same message path.
- Evidence: mixed Android/iOS session, 2026-08-31. The tablet's log recorded
  nineteen distinct unknown group identifiers, twenty-two times each; the
  phone's own startup log confirmed the count as eighteen groups plus one
  personal channel.
- When this lands, create its Kotlin port companion item in the same docs
  pass — [twin parity program](../parity.md), convention 1.
