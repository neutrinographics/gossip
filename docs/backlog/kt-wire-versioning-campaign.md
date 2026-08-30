# Teach both libraries to speak versioned wire formats

**Track:** Kotlin port   **Depends on:** nothing

## What this is

The Dart library and its Kotlin twin talk to each other in production: an
app built on the Dart library syncs with a server built on the Kotlin one.
The two have drifted into speaking slightly different dialects of the same
message format, and the app papers over the difference with a hand-written
translator that rewrites messages as they cross the app–server link.

Meanwhile the current development branch changed how message contents are
encoded. Nothing on the wire announces which encoding a message uses, so a
deployed receiver has no way to tell — it simply fails, and on the server
side it fails without saying anything at all.

This campaign fixes the whole situation at once:

1. **Say which dialect you are speaking.** Every message gains an optional
   one-byte marker at the front identifying its format version. Messages
   without the marker are the old format, which both sides keep
   understanding forever — nothing deployed breaks.
2. **Receive everything, send one thing.** Both libraries learn to read old
   and new formats. What each one *sends* is a configuration setting that
   defaults to the old format, so upgrading a library changes nothing on the
   wire until an operator deliberately flips it, fleet-wide, in order.
3. **Converge the two dialects.** The new format is one shared schema, so
   the app's translator has nothing left to translate and is deleted.
4. **Stop losing errors.** The Kotlin side currently turns every decoding
   failure into silence. That has to end in the same work, or every mistake
   this campaign could make would show up as "sync just doesn't happen".

Alongside the wire work, the campaign carries the rest of the Kotlin port's
catch-up: the Kotlin library was written from the Dart library as it stood
before a round of correctness fixes, and those fixes are being ported batch
by batch. Two pieces of catch-up work depend on the wire settling first and
are therefore part of this campaign's scope rather than separate items:

- **Sending less than everything.** The Kotlin side always answers a request
  with the complete result, however large. Splitting large answers into
  pages, and choosing which summaries to fit into a size-limited message,
  can only be ported once the message format has settled, because the size
  of a message depends on which format it is in.
- **Rotating whose summaries get sent.** When summaries don't all fit, the
  same ones must not win every round — a fairness rotation the Dart library
  already has and the Kotlin one doesn't.

## Why it matters

This is release-blocking in the literal sense: the development branch cannot
ship to the fleet as it stands, because it would silently partition the app
from the server it syncs with. It also removes a permanent tax — right now
every wire change is a three-codebase change (both libraries plus the
translator), which is why the compaction work couldn't cross the app–server
link at all. After this, a wire change is a two-codebase change governed by
shared test fixtures that fail loudly when the two drift.

## Rough approach

Receivers everywhere before senders anywhere. Each library gets one code
module per format version behind a small dispatcher that looks at the first
byte; a shared set of fixture files pins exact bytes for every message in
every dialect, and each consumer keeps a checked copy so drift between the
repositories fails a build rather than a production sync. Deployment is a
strictly ordered sequence of flips — server first to receive, then the app
fleet, then senders — each gated on the previous one being universal.

## Campaign register

Items this campaign is carrying, and where each one durably lives, so
nothing depends on a conversation to survive:

| Carried item | Where it lives |
|---|---|
| Letting the sync side ask the membership side about peers through a proper interface, rather than reaching across the boundary (two places do this: reading reachable peers, and recording peer activity) | **Closed** by Batch KT-B (2026-08-29): the Kotlin library now has the interface (`PeerDirectory` + `MembershipPeerDirectory`), and the architecture test's debt record was deleted in the same change, so the clean edge is machine-enforced. |
| Adopting a peer's claim about our own authorship as a sequence floor (Kotlin side) | **Closed** by Batch KT-B (2026-08-29) — ported alongside the contiguity guard; see the Kotlin repo's `docs/plans/2026-08-29-kt-batch-b-sync-depth.md`. |
| Splitting large answers into pages, and fitting summaries to a size budget, on the Kotlin side | This item's scope, above — after the format settles. The wire spec's out-of-scope section records the reassignment. |
| Rotating which summaries get sent when they don't all fit | This item's scope, above. Shares a surface with [Port the wire-efficiency behaviors to the Kotlin library](kt-port-wire-efficiency.md). |
| Remembering that a derived view needs rebuilding across a crash (Dart side) | Its own item: [Remember that a view needs rebuilding, even across a crash](engine-materializer-rebuild-marker.md). |
| Deleting the app's translator | The wire spec's migration playbook, final step — it is the finish line, not a follow-up. |
| Giving the Kotlin test harness a way to cut a link while both sides keep their state (a real partition, not a remove-and-re-add) | **Closed** by Batch KT-D (2026-08-30): the Kotlin bus grew directional link blocking and node partitioning that leave both sides registered, so a healed node keeps its coordinator state. The Kotlin version ended up stronger than the Dart one it was modelled on — Dart re-registers the port on heal — and the divergence register now recommends the flow-back. |
| Adapting the server to the restructured Kotlin library before the migration playbook's step 4 (the submodule bump) | **Owner-side precondition**, surfaced by the 2026-08-30 scoped audit: the server builds the library from source and imports the old package layout everywhere (27 imports, 17 files), so it does not compile against the restructured library; its Postgres entry repository also needs real implementations of the two new floor methods (`getCompactionFloor`, `adoptVersionFloor` — the engine reads them on live paths, so stubs silently defeat the compaction protections). |
| Wiring the server's error and log callbacks | **Owner-side, same PR as the import fix** (2026-08-30 scoped audit): the server currently passes neither callback, so every diagnostic the new library emits (decode errors, contiguity-gap stalls, authorship-floor warnings) is invisible — a real stall would present as "sync silently stopped" with an empty log. |
| Whether the Kotlin repository's commits should be signed | Open question for the owner; no technical dependency either way. |
| The signed-versus-unsigned message-content mismatch between the spec and the deployed server | **Closed** by the 2026-08-29 documentation pass: the spec now matches what the deployed server actually emits, and every decoder is widened to accept it. |

| Making the Kotlin library's relay-based health probing work at all | Its own item: [Make the Kotlin library's indirect health probing actually work](kt-swim-indirect-probing-inert.md). Found by Batch KT-D (2026-08-30) while translating the failure-detection scenarios, and confirmed from source in review: the relay blocks the queue its own answer must arrive through, so the indirect probe always times out. One Dart scenario stays untranslatable until it is fixed. |
| Translating the rest of the Dart scenario suite | Its own item: [Sweep the remaining scenario coverage into the Kotlin library](kt-scenario-parity-sweep.md). Batch KT-D translated the correctness-bearing core onto the new harness; the scale, multi-channel, and remaining edge/lifecycle groups are mechanical follow-on. |

**Batch KT-D (2026-08-30) is complete.** It ran on two threads. The first
closed four correctness gaps the scoping pass found live in the Kotlin
library — creating a channel that already existed silently wiped its
members and stream configuration; one failing derived-view builder starved
every sibling on the same batch; a peer with a badly wrong clock could drag
the whole mesh's timestamps forward unbounded; and two concurrent writes to
one stream could race for the same sequence number and fail one of them —
and added the two regression pins the inventory still owed. The second
built the Kotlin library its first end-to-end scenario harness (a network
DSL, link conditions, and a simulated clock that fires timers the way the
Dart one does) and translated roughly sixty Dart scenarios onto it,
including the congestion group, which is the first test anywhere that pins
the Kotlin library's shipped congestion gate against a real queue rather
than a declared number. The suite went from 795 tests to well over 900.

Two findings came out of it that outlive the batch: the relay-probing
defect and the scenario-parity remainder, both now their own items above.
What remains of the campaign's later batches is KT-E.

**Batch KT-B (2026-08-29) is complete.** Between the two rows above and the
audit-inventory items it also ported (the per-author contiguity guard with
gap reporting, and the flip from silent-skip to throwing on duplicate
appends — inventory items 3 and 9 of the
[Kotlin port fix inventory](../superpowers/specs/2026-08-28-kt-port-dart-fix-inventory.md)),
this batch closes the contiguity-guard, duplicate-throw, PeerDirectory-ACL,
and authorship-floor items entirely. What remains of the campaign's later
batches is KT-C/D/E.

## Related

- The design: [wire versioning spec](../superpowers/specs/2026-08-28-wire-versioning.md)
  (its decision record holds the owner's rulings), built on two verified
  reconnaissance records —
  [what the wire actually carries](../superpowers/specs/2026-08-28-wire-recon-facts.md)
  and [what the deployed server and app actually run](../superpowers/specs/2026-08-28-vendored-kt-recon.md).
- The execution plan across the three repositories:
  [wire/codec batch](../superpowers/plans/2026-08-29-wire-codec-batch.md).
- The port catch-up list this campaign works through:
  [Kotlin port fix inventory](../superpowers/specs/2026-08-28-kt-port-dart-fix-inventory.md).
- The pre-batch review that produced this item and the register above:
  [foundation audit](../superpowers/specs/2026-08-29-foundation-audit.md).
- Siblings: [Audit the Kotlin library for the bug classes fixed in Dart](kt-audit-legacy-bug-classes.md),
  [Port the wire-efficiency behaviors to the Kotlin library](kt-port-wire-efficiency.md),
  [Mirror the bounded-context structure in the Kotlin library](kt-mirror-bounded-contexts.md),
  [Record where the Dart library and its Kotlin twin diverge, with a verdict](kt-normalize-twin-divergences.md)
  — several of this batch's disclosed deviations (frame dispatch, decode
  failure contract, entry insertion order, pending-request expiry) are
  seeded into that register.
