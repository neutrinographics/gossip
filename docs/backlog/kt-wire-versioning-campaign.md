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
| Letting the sync side ask the membership side about peers through a proper interface, rather than reaching across the boundary (two places do this: reading reachable peers, and recording peer activity) | The Kotlin library's architecture test records it as accepted debt, and the test fails if the debt is paid without deleting the record. Scheduled inside this campaign. |
| Splitting large answers into pages, and fitting summaries to a size budget, on the Kotlin side | This item's scope, above — after the format settles. The wire spec's out-of-scope section records the reassignment. |
| Rotating which summaries get sent when they don't all fit | This item's scope, above. Shares a surface with [Port the wire-efficiency behaviors to the Kotlin library](kt-port-wire-efficiency.md). |
| Remembering that a derived view needs rebuilding across a crash (Dart side) | Its own item: [Remember that a view needs rebuilding, even across a crash](engine-materializer-rebuild-marker.md). |
| Deleting the app's translator | The wire spec's migration playbook, final step — it is the finish line, not a follow-up. |
| Whether the Kotlin repository's commits should be signed | Open question for the owner; no technical dependency either way. |
| The signed-versus-unsigned message-content mismatch between the spec and the deployed server | **Closed** by the 2026-08-29 documentation pass: the spec now matches what the deployed server actually emits, and every decoder is widened to accept it. |

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
  [Mirror the bounded-context structure in the Kotlin library](kt-mirror-bounded-contexts.md).
