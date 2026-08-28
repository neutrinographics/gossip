# Wire versioning: a single-byte version prefix across gossip (Dart) and gossip-kt

**Status:** APPROVED — owner-ruled; normative for implementers. The three
decisions in §11 were ruled on 2026-08-29, and the spec was amended the same
day (see "Amendments" below) to match the deployed wire the goldens pin.
**Audience:** first the project owner; then implementers in two repos
(`gossip` on `working-connection`, `gossip-kt` on `feature/compaction`).
**Evidence base:** all wire facts cited below come from two verified recons —
[`2026-08-28-wire-recon-facts.md`](2026-08-28-wire-recon-facts.md) (cited as
"recon §N" with its file:line references) and
[`2026-08-28-vendored-kt-recon.md`](2026-08-28-vendored-kt-recon.md) (cited as
"vendored recon §N"; covers the deployed server's gossip-kt pin and
OpenDoorApp's `ProtocolTranslator`) — spot-checked against
`packages/gossip/lib/src/sync/infrastructure/sync_message_codec.dart` and
`packages/gossip/lib/src/membership/infrastructure/membership_message_codec.dart`
on `working-connection`. Deployment facts (server pin, translator role, flat-vs-
envelope decision) were owner-confirmed on 2026-08-28.

Every design decision in this document was chosen by the drafting pass, not
by the owner, and is open to the owner's veto. The **fixed requirements** are
not: gossip-kt is the server-side twin of the Dart library — deployed today
as a git submodule of standalone gossip-kt `main` @ `5255d74`, with zero
divergence (vendored recon §1–§2) — and needs full bidirectional wire parity;
the deployed application pinned to Dart `main` @ `73f6a58` speaks the legacy
wire (and bridges to the server via its `ProtocolTranslator` shim, §1) and
must never break; the chosen direction is a single-byte wire-version prefix
on frames; and codec versioning must be easy to manage across the two
libraries.

---

## Amendments (2026-08-29)

The foundation audit
([`2026-08-29-foundation-audit.md`](2026-08-29-foundation-audit.md), §B)
compared this spec field-by-field against both libraries' codecs and the
seven committed v1-kt golden fixtures. The Dart-side schemas were exact; six
drifts on the v1-kt side were found and are corrected here. The corrections
are the owner's, ruled 2026-08-29:

1. **Payload signedness (§7.2, §7.4, §8c).** The deployed gossip-kt server
   emits entry payload bytes as **signed** JSON ints (`-128`–`127`) — the
   goldens are ground truth, and the spec's flat "0–255, reject anything
   else" rule would have instructed an upgraded translator to reject the
   live server's normal traffic. The rule is now: upgraded emission
   normalizes to unsigned `0`–`255`, every v1 decoder accepts the widened
   `-128`–`255` and normalizes negatives, the translator normalizes
   in-flight, and rejection applies only **outside** `-128`–`255`.
2. **Integer width (§7.1).** `sequence` and version-vector values are fixed
   at 32-bit across both dialects; kt decodes them as `Int` today and Dart's
   64-bit `int` would silently overflow that.
3. **`floor`/`hasMore` are a kt domain-model change (§6.1, §7.4)**, not a
   codec key addition — kt's delta messages carry no such fields at all.
4. **Empty-frame contract (§4 rule 1)** now cross-references §6.2: kt
   returns `null` today and gains the reported-error contract as part of
   this work.
5. **kt pagination/budgeting reassigned (§10)** from "the wire batch" to the
   port campaign's post-KT-B engine work.
6. **kt's `PingReq.originalRequester` is dropped at v2 (§11 decision 4).**

---

## 1. Motivation

Four facts force this work now.

**1. The deployed app speaks a wire that the current branch already broke.**
A deployed application is git-pinned to Dart `main` @ `73f6a58` — the legacy,
unprefixed wire: first byte is the message type (0–6), entry payloads are
JSON int arrays, no `floor`/`hasMore` fields. The `working-connection` branch
changed entry payloads to base64 strings, and **both** legacy receivers choke
on that: v1 Dart throws a `TypeError` on the `as List` cast
(recon §1c; `protocol_codec.dart:353`) and reports a
`PeerSyncError(messageCorrupted)` per frame, while gossip-kt — the deployed
server — swallows the failure into a silent `null` and drops the whole
message with no trace (recon §2c; `ProtocolCodec.kt:64-71, :323`). Shipping
`working-connection` into a mixed fleet without a versioning story would
partition the fleet by dialect. Breaking the deployed app is unacceptable,
so each library must keep receiving its own legacy wire alongside the new
one.

**2. The two libraries cannot natively exchange deltas — today a
hand-written shim bridges them.** kt's `DeltaRequest`/`DeltaResponse` use a
batched nested-map envelope (`{sender, entries: {channelId: {streamId:
[...]}}}`, `GossipMessages.kt:44-61`; vendored recon §3) that is
structurally incompatible with both Dart dialects' flat per-(channel,
stream) shape. A Dart-shaped delta fails kt's decoder (`.jsonObject` throws
on a JSON array, blanket-caught, silently nulled); a kt-shaped delta fails
both Dart decoders (missing top-level `channelId`). At the library level,
only SWIM messages and digests interop (recon §6). And yet Dart↔Kotlin sync
works in production TODAY: the deployed server is a git submodule of
standalone gossip-kt `main` @ `5255d74` with zero divergence (vendored recon
§1–§2), and the deployed app bridges the schema gap with `ProtocolTranslator`
(`OpenDoorApp/lib/features/sync/infrastructure/gossip/protocol_translator.dart`,
wired into `websocket_connection_service.dart`), which re-nests flat Dart
deltas into kt's batched envelope on send and fans one batched kt message
out into N flat Dart messages on receive, at the app↔server WebSocket
boundary (vendored recon §4, §7). So kt's batched shape is not an orphan —
it has deployed users on both ends of every WebSocket link.

**3. v2 retires the translator.** The shim is the tax on every future wire
change: each new field or message needs hand-written translator support
before it can cross the app↔server link — the v2 `floor` field, the
centerpiece of the compaction fix, could not cross the WebSocket link
without translator surgery, because the translator rebuilds delta payloads
key by key. With both libraries speaking identical prefixed v2 schemas
natively, the translator has nothing left to translate and is deleted
(§5.3). This is a headline motivation for v2, not a side effect: it turns
every future cross-language wire change from a three-codebase problem
(Dart, kt, translator) into a two-codebase one governed by shared
conformance vectors (§8).

**4. The port inventory's item 12 framed wire contracts as "not
port-relevant unless cross-language interop is ever a real goal"
([`2026-08-28-kt-port-dart-fix-inventory.md`](2026-08-28-kt-port-dart-fix-inventory.md),
item 12). That framing is WRONG and this spec corrects it:** interop is not
a hypothetical — gossip-kt is the server-side twin of the Dart library, and
full bidirectional wire parity with Dart's codec is a fixed requirement.
Item 12's contract details (base64 payloads, additive `floor`/`hasMore`,
type-byte framing, decode-null-for-sibling-family) are therefore
**mandatory** port targets, not optional completeness notes. Implementers
reading the inventory should treat item 12's priority line as superseded by
this spec.

One piece of good news underpins the whole design: all three dialects
already agree byte-for-byte on the seven type bytes 0–6 (recon §3b), both v1
decoders provably ignore unknown JSON keys (recon §1c, §2e — additive fields
are free), and the byte range `0x07`–`0xFF` at the codec's first-byte
position is unclaimed by every dialect and both transports (recon §4c).
There is room for a version marker, and additive evolution is safe.

---

## 2. Version model

*(Decision 1 — controller-chosen, open to veto.)*

**v1** is the legacy unprefixed wire: first byte = message type 0–6, then a
UTF-8 JSON object, entry payloads as JSON int arrays, no `floor`/`hasMore`.
It comprises **two live schema dialects**, both deployed today:

- **v1-dart** (flat): what the deployed app (Dart `main` @ `73f6a58`)
  speaks — app↔app over Nearby, and the app side of the WebSocket link
  before translation. Deltas are flat per-(channel, stream) messages
  (recon §1d). Normative schemas: §7.2.
- **v1-kt** (batched): what the deployed server (gossip-kt `main` @
  `5255d74`, via submodule — vendored recon §1) speaks — deltas batched
  across all channels/streams as nested maps, plus an `originalRequester`
  field on PingReq (vendored recon §3–§4). Normative schemas: §7.4.

The two dialects are bridged on the app↔server WebSocket link — the only
cross-dialect link in the deployment — by the app's `ProtocolTranslator`
(vendored recon §4). Neither library decodes the other's v1 dialect, today
or after this work; the translator carries that load until v2 (§4, §5.3).

**v2** is the first PREFIXED wire: `[marker byte 0xF2][type byte][UTF-8 JSON
payload]` — ONE schema set shared identically by both libraries. The payload
schemas are `working-connection`'s current ones: base64 entry payloads,
`hasMore` always present, `floor` present when non-empty, **flat
per-(channel, stream) deltas** (recon §3d; `sync_message_codec.dart:110-122`).
The flat shape is an owner decision (2026-08-28): v2 proceeds flat; a
budget-aware batch envelope in the spirit of v1-kt's batching is a future
consideration only (§10).

**Key simplification, stated prominently:** `working-connection`'s *current*
wire — unprefixed frames carrying base64 payloads — has ZERO deployed users.
It therefore never becomes a version. As part of this work, Dart
`working-connection` adopts the prefix, and the unprefixed-base64 interim
form dies without ever shipping and without migration debt. kt's batched
shape is expressly NOT in that category: it has deployed users (the server,
and every deployed app's translator, on both ends of every WebSocket link),
so it is a real dialect — v1-kt — that kt must keep emitting and accepting
through the migration, retiring only when the fleet is fully v2 (§5.3,
§6.1). There are exactly two wire versions in existence after this work —
v1 (in its two dialects) and v2 — not three.

Version-bump policy: **additive JSON fields stay within a version** — both
v1 decoders were proven to ignore unknown keys (recon §1c, §2e), and v2
inherits the same manual-key-read tolerance — so a new optional field never
requires a marker bump. The marker bumps only for breaking changes (payload
encoding changes, envelope reshapes, field renames/removals, semantics
changes to existing fields).

**Receive is permanent, per dialect:** receivers in each library accept
unprefixed frames in **their own** v1 dialect AND prefixed frames — Dart
receives v1-dart-flat + v2; kt receives v1-kt-batched + v2. Neither library
ever needs to decode the other's v1 dialect (the translator covers the only
cross-dialect link, and only until v2). Dart's v1 receive has no sunset;
kt's v1-kt support retires only when the fleet is fully v2 and the
translator is deleted (§5.3). Send is what gets versioned (§5).

---

## 3. Frame format

### 3.1 v1 frame (unprefixed, legacy)

```
[type byte: 0x00–0x06][UTF-8 JSON object]
```

Type bytes: Ping=0, Ack=1, PingReq=2, DigestRequest=3, DigestResponse=4,
DeltaRequest=5, DeltaResponse=6 — identical across all three dialects
(recon §3b). Schemas: §7.2 (v1-dart) and §7.4 (v1-kt).

### 3.2 v2 frame (prefixed)

```
[version marker: 0xF2][type byte: 0x00–0x06][UTF-8 JSON object]
```

The type-byte table is unchanged — v2 reuses the same seven assignments
after the marker. Schemas in §7.3.

### 3.3 First-byte marker table

*(Decision 2 — controller-chosen, open to veto.)*

The recon established that `0x07`–`0xFF` is unclaimed at this byte position
by v1 Dart, v2 Dart, gossip-kt, gossip_nearby (whose `0x01`/`0x02` envelope
lives in an outer framing layer the marker never occupies — recon §4a), and
gossip_bluey (which never inspects payload bytes — recon §4b).

| First byte | Meaning |
|---|---|
| `0x00`–`0x06` | v1 frame; the byte is itself the message type |
| `0x07`–`0xEF` | Reserved, unassigned. Decode error. |
| `0xF0`–`0xF1` | Version-marker range, but permanently unassigned: version 0 does not exist, and version 1 is *defined* as the unprefixed form, so a `0xF1`-prefixed frame is illegal. Decode error. |
| `0xF2`–`0xFE` | Version marker: **version = byte − 0xF0**. `0xF2` ⇒ v2, `0xF3` ⇒ v3, … `0xFE` ⇒ v14. Unregistered versions are a decode error. |
| `0xFF` | Escape byte reserved for a future extended-version form (e.g. `[0xFF][varint version][...]`) if versions ever exceed 14. Currently undefined; decode error. |

### 3.4 Why a single self-describing marker byte (vs fixed magic + version byte)

The considered alternative was a fixed magic byte (say `0xF0`) followed by a
separate version byte: `[0xF0][version][type][JSON]`. It loses on every
axis that matters here:

- **Size:** two bytes of overhead per frame instead of one, on a wire whose
  budget discipline exists because of a 32KB transport ceiling.
- **Self-description:** with the arithmetic form, the version is read
  directly from the first byte; there is no second parse step before the
  frame's dialect is known.
- **Headroom:** `0xF2`–`0xFE` gives 13 assignable versions before the
  `0xFF` escape is ever needed. This project has bumped its wire once in
  its entire history; 13 breaking revisions of headroom is ample, and the
  escape means even exhaustion is not a dead end.
- The magic-byte form's only real advantage — a slightly sharper corruption
  signal (fixed sentinel vs a 13-value range) — is marginal, because a
  corrupt frame fails JSON decode immediately anyway and both Dart engines
  already report malformed frames per-message without killing the receive
  loop (recon §1b, §3c).

Placing the markers at the top of the byte range (rather than starting at
`0x07`) keeps a wide unassigned buffer between the type-byte space and the
marker space, so both remain visually unmistakable in a hex dump and any
byte in `0x07`–`0xEF` is an unambiguous corruption signal.

---

## 4. Receive rules

Every receiver in both libraries, after this work, classifies an inbound
core-codec frame by its first byte:

1. **Empty frame** → decode error (existing contract in both Dart dialects:
   `ArgumentError('Cannot decode empty bytes')`, recon §1b, §3c). This is
   the target contract, not the current state on the kt side: kt returns a
   silent `null` for an empty frame today (`SyncMessageCodec.kt:64`,
   `MembershipMessageCodec.kt:53`) and acquires the reported-error contract
   as part of §6.2's work.
2. **`0x00`–`0x06`** → v1 frame. Route to the library's **own-dialect** v1
   codec module: v1-dart-flat (§7.2) in Dart, v1-kt-batched (§7.4) in kt.
   Decode the legacy schema into the current domain messages — for
   `DeltaResponse` this means `hasMore` defaults to `false` and `floor` to
   empty, which the v2 Dart decoder already does for legacy frames
   (recon §3d; `sync_message_codec.dart:263-267`); for kt it additionally
   means fanning the batched envelope out into flat per-(channel, stream)
   domain messages (§6.1). Neither library implements the *other's* v1
   dialect: no v1-kt frame ever reaches a Dart node and no v1-dart-flat
   frame ever reaches a kt node, because the only cross-dialect link is the
   app↔server WebSocket, where the app's `ProtocolTranslator` converts
   between the dialects until the fleet is v2 (vendored recon §4; §5.3).
3. **`0xF2`** → v2 frame. Strip the marker; the remainder is
   `[type byte][JSON]`, decoded by the v2 codec module (§7.3).
4. **`0xF3`–`0xFE` (unregistered versions), `0xF0`–`0xF1`, `0xFF`,
   `0x07`–`0xEF`** → decode error: reported via the library's error channel
   (`ErrorCallback` in Dart; kt per §6.2), frame dropped, receive loop
   survives. Never silent.

**Dart-specific shape of the dispatch.** In v2 Dart, both engines
independently run their own family codec over the full incoming stream, and
the sibling-family contract is: null for "not mine," throw for "unknown"
(recon §3c; `sync_message_codec.dart:39-59`,
`membership_message_codec.dart:30-49`). The version dispatch must preserve
that contract *per version*: each context's codec facade sniffs byte 0,
strips a marker when present, and then applies the family split to the type
byte — so a v2-prefixed membership frame still decodes to null in the sync
codec and decodes for real in the membership codec. `WireTypes` (or a
successor) must own the marker-range knowledge, exactly as it owns the
type-byte partition today, so the boundary architecture is unchanged.

**Receive-both is the invariant.** No flag disables a library's own-dialect
v1 receive during the migration; a node that can decode only one of (its
own v1, v2) is precisely the failure this spec exists to prevent. Dart's
v1 receive stays forever; kt's v1-kt receive may be retired once the fleet
is fully v2 and the translator is deleted — at that point no peer anywhere
produces batched v1 frames (§5.3 step 8).

---

## 5. Send gating and migration playbook

### 5.1 Config, not negotiation

*(Decision 3 — controller-chosen, open to veto.)*

Each library gains one config setting — an enum `WireVersion` with values
`.v1`/`.v2` (Dart: `wireVersion` on `CoordinatorConfig`; kt: the equivalent
field on its coordinator config — owner decision 2026-08-29, §11) — that
selects the **send** dialect: `v1` emits unprefixed legacy frames, `v2`
emits prefixed frames. Receive is always both, regardless of the setting.
**The library default is `.v1` in both libraries** (owner decision
2026-08-29, §11), so an app that upgrades the library without touching
config changes nothing on the wire. The deployed kt server does not get a
different library default to reach v2-send early; instead it flips
explicitly at deploy time once its gate (§5.3 step 7) is met. When (if
ever) the *library* default itself flips from v1 to v2 is deferred to the
≥3.0.0 pub.dev publish decision, not scheduled by this spec (§11).

**Why not runtime negotiation, in one paragraph:** today's entire interop
surface is a single coordinated fleet (one deployed app fleet plus the
deployed kt server it syncs with), so a config flip administered with the fleet's own release
process is sufficient, simpler, and testable — no handshake state machine,
no per-peer dialect table, no downgrade-attack surface. Negotiation is
strictly additive later: the natural shape is a capability field
(e.g. `"wire": [1, 2]`) carried in an existing message, which is itself just
an additive JSON key — and the recon proved both v1 decoders ignore unknown
keys safely (recon §1c, §2e), so a future negotiating node can advertise to
a v1 fleet without breaking anything. A sender would then pick the highest
version both ends advertise, falling back to v1 for peers that never
advertise. That is a sketch of the future shape, deliberately not designed
here.

### 5.2 Rollout ordering constraint (from the recon — not optional)

Both Dart engines independently run a codec over the full incoming stream,
so a first byte neither codec recognizes throws in both and is reported via
`ErrorCallback` **twice per frame** (recon §1b for v1, §3c for v2 — the
recon flags this explicitly as "a direct constraint on any version-prefix
design"). Today's kt — the deployed server — is worse: an unknown byte
becomes a silent null (recon §2b). Therefore:

> **Receivers everywhere must learn the marker range and v2 — alongside
> their own v1 dialect — BEFORE any sender that reaches them flips to v2.**

Sequencing inside each release matters too: the receive-side work (marker
dispatch, v1 codec module) and the send-gating config can land in one
library release, because the default is v1-send — the dangerous state is
only ever created by flipping config before the fleet's receivers are
upgraded (§9).

### 5.3 Migration playbook

Numbered, in strict order. Steps 1–3 are code work (the two libraries,
plus the translator suite in the app's tests); 4–8 are deployment.

1. **Dart (`working-connection`):** introduce the version-dispatching codec
   facades; add the v1 codec modules (legacy v1-dart-flat emission:
   int-array payloads, no `hasMore`, additive `floor` per §11 decision 3);
   keep the current schemas as the v2 modules, now emitted behind the
   `0xF2` marker; add `wireVersion` config (`WireVersion.v1`/`.v2`),
   default `.v1` (§11 decision 1). The unprefixed-base64 interim wire
   ceases to exist here (§2).
2. **gossip-kt:** keep the batched schema as the **v1-kt codec module** —
   its v1 emission and acceptance stay byte-identical to the deployed
   server's wire, because every deployed app's translator produces and
   expects exactly that shape (§6.1); add a **v2 codec module** speaking
   the shared flat per-(channel, stream) schema behind the `0xF2` marker;
   replace blanket-catch-null decode with reported decode failure (§6.2);
   add the same version-dispatching receive and `wireVersion` config
   (`WireVersion.v1`/`.v2`), default `.v1` (§11 decision 1) — the server
   flips to `.v2` explicitly at deploy time (step 7), not via a changed
   library default.
3. **Conformance vectors (§8):** land the golden vector files (v1-dart,
   v1-kt, v2) in the Dart repo, vendor them into gossip-kt with the
   checksum-pinned sync test, get both CI suites green, and land the
   translator round-trip suite in OpenDoorApp pinning the shim against the
   v1-dart and v1-kt sets. No sender may flip to v2 before this step is
   green — the vectors are the proof that receive-both actually holds.
4. **Server deploy:** bump the opendoor-api submodule to the new gossip-kt
   and deploy with default v1-send. Wire traffic is byte-identical to
   today (v1-kt-batched), so old apps' translators are unaffected; the
   server can now also *receive* prefixed v2 frames.
5. **Deployed app fleet upgrade:** ship the app with the new Dart library,
   still sending v1 (the default — no config change needed) and **keeping
   the `ProtocolTranslator`** for the server link's v1 traffic; the
   translator additionally passes prefixed v2 frames through untouched.
   Wire traffic is byte-identical to today; the only change is that every
   upgraded app can now *receive* prefixed frames — from peers and from
   the server. Old and new app builds coexist freely during this phase.
6. **Apps flip to v2:** once every fleet node is confirmed upgraded (per
   §5.1 this is a fleet-administration fact, not something the protocol
   detects), ship an app release setting `wireVersion` to v2. During any
   overlap, v2-sending nodes still receive v1 from stragglers — but a
   *straggler on the old pin* receiving v2 gets per-frame error noise and
   effective partition (§9), which is why this step waits for full fleet
   upgrade, not majority. The server (step 4) already receives v2, so the
   WebSocket link is unaffected by the flip.
7. **Server flips to v2:** the server may flip to v2-send **only after
   every app it serves is v2-receive-capable** (has passed step 5) — an
   old app's translator understands only batched v1-kt from the server; a
   prefixed frame reaching it is error noise and effective partition on
   that link (§9). This is strictly *after* full fleet upgrade, never
   "day one", because the server always launches against whatever apps
   exist in the field.
8. **Delete the translator:** once the server AND the fleet both send v2,
   no v1 traffic crosses the WebSocket link in either direction. The app's
   `ProtocolTranslator` is deleted, and kt's v1-kt codec module may retire
   with it (§2, §6.1). This is the finish line that fact 3 of §1 promised.

**Future versions (v3+):** same two-phase rule, now cheap: add a v3 codec
module and vectors behind marker `0xF3`, ship receivers everywhere, then
flip senders. The dispatch facade and vector harness make this additive —
and with the translator gone, there is no third codebase to teach.

---

## 6. gossip-kt convergence requirements

### 6.1 Delta schema convergence at v2 — while v1-kt stays live

*(Decision 4 — controller-chosen, open to veto; scope revised 2026-08-28
after the vendored-kt recon.)*

kt's **domain messages** converge on Dart's flat per-(channel, stream)
shape — not just a codec translation layer, since the shape difference (one
message per stream pair vs one message batching everything) is visible to
engine logic (budgeting, pull tracking, floor scoping are all per-stream in
Dart). But on the **wire**, the batched shape is a live, deployed dialect
(v1-kt), not dead code to delete up front. Concretely:

- **kt's v2 codec emits and accepts the shared v2 schema** (§7.3) — flat
  `channelId`/`streamId`/`since`/`entries` envelope, base64 payloads,
  `hasMore`, optional `floor`. Identical to Dart's v2, byte for byte,
  proven by the shared vectors (§8).
- **kt's v1 codec module keeps emitting and accepting the batched v1-kt
  wire shape (§7.4) through the migration.** Every deployed app's
  translator expects batched frames *from* the server and produces batched
  frames *toward* it (vendored recon §4); a kt release that stopped
  speaking batched v1 would break every existing app the moment the server
  deployed it. At the codec boundary, the v1-kt module maps batched wire ↔
  flat domain messages — batching per-stream messages on encode, fanning a
  batched frame out on decode — the same transformation the app translator
  performs today, now living inside kt's v1 codec module instead.
- The batched shape retires **only when the fleet is fully v2** (§5.3
  step 8), together with the translator. It is emphatically NOT in the
  "retired, never a version" category that Dart's unprefixed-base64
  interim form is in (§2): that form has zero deployed users; v1-kt has
  the deployed server and every deployed app's translator.

Without the v2 convergence, the version prefix is decoration: a v2 marker
on two different schemas is not one version. `Ping`/`Ack`/`DigestRequest`/
`DigestResponse` are already field-compatible across all three dialects
(recon §6, final paragraph) and need only the marker/dispatch work.
`PingReq` differs only on v1-kt's extra `originalRequester` field (§7.4);
the v2 schema is Dart's (§7.3 — types 0–5 identical to v1-dart), and the
field is **dropped** at v2 rather than carried as an additive key, because
kt's own reads of it are equivalent to reading `sender` (§11 decision 4).

### 6.2 kt decode failures must be reported, not nulled

*(Decision 5 — controller-chosen, open to veto.)*

kt's `ProtocolCodec.decode` currently converts every failure — unknown type
byte, corrupt JSON, missing key, wrong-shaped payload — into a `null` that
the single production call site ignores with no log and no error callback
(recon §2b, §2f; `ProtocolCodec.kt:61-72`, `Coordinator.kt:285-303`; the
outer catch there is dead code for decode failures). This violates the
project's no-silent-errors rule directly, and worse: silent nulls would
mask *every* interop bug this spec exists to prevent — a misconfigured
v2 sender, a schema drift, a vector mismatch would all present as "kt just
doesn't sync" with zero diagnostics. The fix is part of this work, not a
follow-up: decode failures must surface through kt's error-reporting path
(the analogue of Dart's `PeerSyncError(messageCorrupted)` emission —
recon §1b), with the same resilience contract: report, drop the frame,
keep the receive loop alive. The "not mine / sibling family" null (if kt
adopts Dart's split-codec shape) or its unified-codec equivalent remains a
non-error; only genuine decode failures report.

---

## 7. Schema appendix

Complete enough that a codec implementer needs no other document. Field
names are exact; nesting is exact. Sources: recon §1d (v1-dart, from
`protocol_codec.dart:136-230` at `73f6a58`), recon §3d/§3e plus direct
verification of `sync_message_codec.dart` / `membership_message_codec.dart`
on `working-connection` (v2), recon §6 and vendored recon §3–§4 (v1-kt, from
`GossipMessages.kt`/`ProtocolCodec.kt` at the deployed pin `5255d74`).

### 7.1 Common encodings (identical in v1 and v2)

- A frame's JSON payload is a single UTF-8-encoded JSON object.
- **NodeId / ChannelId / StreamId:** plain JSON strings (the value-object's
  string value).
- **VersionVector:** JSON object mapping NodeId string → sequence int:
  `{"nodeA": 5, "nodeB": 12}`.
- **Integer width (normative, both dialects and both versions):** entry
  `sequence` and every version-vector value are **32-bit signed** — max
  `2^31 − 1`. kt decodes both with `.int` into an `Int` field, so a
  Dart-origin value above that range does not survive the crossing; Dart's
  64-bit `int` must therefore be treated as 32-bit-bounded on the wire. A
  value that exceeds the range is corruption, reported like any other
  decode failure — never silently truncated or nulled.
- **Hlc (timestamp):** `{"physicalMs": <int>, "logical": <int>}`.
  (`physicalMs` is a Dart int / Kotlin Long; JSON does not distinguish —
  recon §6.)
- **Decoder tolerance:** unknown JSON keys are ignored in every dialect and
  every version (manual key reads, nothing iterates the key set —
  recon §1c, §2e). Implementations must preserve this: never switch to a
  strict/exhaustive-key decode.
- Integers are JSON numbers without fraction; no floats appear anywhere on
  the wire.

### 7.2 v1-dart schemas (frame = `[type][JSON]`) — the deployed app's dialect

| Type | Byte | JSON schema |
|---|---|---|
| Ping | 0 | `{"sender": <NodeId>, "sequence": <int>}` |
| Ack | 1 | `{"sender": <NodeId>, "sequence": <int>}` |
| PingReq | 2 | `{"sender": <NodeId>, "sequence": <int>, "target": <NodeId>}` |
| DigestRequest | 3 | `{"sender": <NodeId>, "digests": [<ChannelDigest>]}` |
| DigestResponse | 4 | `{"sender": <NodeId>, "digests": [<ChannelDigest>]}` |
| DeltaRequest | 5 | `{"sender": <NodeId>, "channelId": <ChannelId>, "streamId": <StreamId>, "since": <VersionVector>}` |
| DeltaResponse | 6 | `{"sender": <NodeId>, "channelId": <ChannelId>, "streamId": <StreamId>, "entries": [<Entry-v1>]}` |

Where:

- `ChannelDigest` = `{"channelId": <ChannelId>, "streams": [<StreamDigest>]}`
- `StreamDigest` = `{"streamId": <StreamId>, "version": <VersionVector>}`
- `Entry-v1` = `{"author": <NodeId>, "sequence": <int>, "timestamp": <Hlc>,
  "payload": [<int>, ...]}` — payload is a **JSON int array** of byte
  values. The signedness rule is asymmetric between emission and decode,
  and this asymmetry is normative for **both** v1 dialects:
  - **Emission** (every upgraded implementation): unsigned `0`–`255`.
  - **Decode** (every v1 decoder, in both libraries and in the app's
    translator): accept the widened range `-128`–`255`, normalizing a
    negative element to its unsigned byte value (`n + 256`, equivalently
    `& 0xFF`). The widening is not laxity: the **deployed** gossip-kt
    server emits signed ints today (§7.4), so a decoder that rejects them
    rejects live traffic.
  - **Reject** only elements **outside** `-128`–`255` — those cannot be a
    byte under either interpretation, and are corruption. They are never
    truncated mod 256.

  Dart's existing legacy-decode path (`sync_message_codec.dart:319-335`)
  implements the narrow `0`–`255` form and is **widened** by this work to
  the range above.

v1-dart emission omits `hasMore` — continuation stays v2-only, since it
degrades gracefully without a signal (see below) and the ruling found no
equivalent payoff to including it in v1 (§11 decision 3). It **does emit
`floor` additively**, encoded exactly as v2 does (§7.3), when non-empty:
the owner ruled (2026-08-29, §11 decision 3) that v1-send DeltaResponse
carries `floor` so upgraded peers get the compaction-floor benefit while
the fleet is still v1-sending, while old peers ignore the unknown key per
the decoder-tolerance guarantee (§7.1; recon §1c). The v1-dart DECODE
schema is unchanged by this — a frame without `floor` still decodes to an
empty VersionVector; only the emission side gained the new key, captured
as the "v1+floor" vector variant (§8c). A v1-mode sender
that internally truncates a delta to fit its budget simply omits the
continuation signal; the remaining entries arrive via subsequent
anti-entropy rounds when the next digest exchange shows the peer still
behind — the same way the deployed v1 app converges today, which has never
had `hasMore`. Implementers should verify this degradation path with a
vector-driven engine test rather than taking it on faith.

### 7.3 v2 schemas (frame = `[0xF2][type][JSON]`)

Types 0–5 (Ping, Ack, PingReq, DigestRequest, DigestResponse,
DeltaRequest): **JSON schema identical to v1-dart (§7.2)** (recon §3d —
"same key names, same nesting"). Only the frame gains the marker. Per the
owner's 2026-08-28 decision, v2 deltas stay **flat per-(channel, stream)**;
kt's batched envelope does not carry into v2 (batch envelope: future only,
§10).

Type 6, DeltaResponse:

```
{"sender": <NodeId>, "channelId": <ChannelId>, "streamId": <StreamId>,
 "entries": [<Entry-v2>], "hasMore": <bool>, "floor": <VersionVector>}
```

- `hasMore` — **always present** on encode. `true` means the responder
  truncated to fit its byte budget and the requester should follow up.
  Decode: absent → `false` (`sync_message_codec.dart:263`).
- `floor` — present **only when non-empty** (`sync_message_codec.dart:
  117-121`: "Omitted when empty ... legacy decoders ignore unknown keys");
  carries the responder's reportable compaction floor. Decode: absent →
  empty VersionVector (`:265-267`).
- `Entry-v2` = `{"author": <NodeId>, "sequence": <int>, "timestamp": <Hlc>,
  "payload": <base64 string>}` — payload is **standard base64** of the raw
  bytes (`sync_message_codec.dart:167`).
- Decoder grace (existing, keep): the v2 decoder's payload reader accepts
  both the base64 string and a legacy int list, DeltaResponse entries only
  (recon §3e; `:319-335`), under §7.2's widened element rule (`-128`–`255`
  accepted and normalized; outside that, rejected). Canonical v2 emission
  is base64; the conformance vectors pin base64.

### 7.4 v1-kt schemas (frame = `[type][JSON]`) — the deployed server's dialect

**Normative.** This is the second live v1 dialect (§2): the wire spoken by
the deployed server (gossip-kt `main` @ `5255d74`) and expected/produced by
every deployed app's `ProtocolTranslator` on the WebSocket link. kt's v1
codec module must keep emitting and accepting it through the migration; it
retires only at §5.3 step 8, when the fleet is fully v2.

Types 0 (Ping), 1 (Ack), 3 (DigestRequest), 4 (DigestResponse): identical
to v1-dart (§7.2) — field-compatible across all three dialects (recon §6).
Differences:

| Type | Byte | JSON schema |
|---|---|---|
| PingReq | 2 | `{"sender": <NodeId>, "sequence": <int>, "target": <NodeId>, "originalRequester": <NodeId>}` — kt adds `originalRequester`; the app translator injects it on the way to the server (vendored recon §4). v1-kt emission keeps the 4-key form for deployed compatibility, always with `originalRequester` = `sender`; decode tolerates the key's absence. The field does not exist at v2 (§11 decision 4). |
| DeltaRequest | 5 | `{"sender": <NodeId>, "channelDeltas": {<ChannelId>: {<StreamId>: <VersionVector>}}}` — batched across ALL channels/streams in one message; the innermost map (author NodeId → since-sequence int) is the version-vector shape. No top-level `channelId`/`streamId`/`since` keys (vendored recon §3; `GossipMessages.kt`: "channelId -> streamId -> authorNodeId -> sinceSequence"). |
| DeltaResponse | 6 | `{"sender": <NodeId>, "entries": {<ChannelId>: {<StreamId>: [<Entry-v1>]}}}` — nested maps, no top-level `channelId`/`streamId` (vendored recon §3; `GossipMessages.kt`: "channelId -> streamId -> list of entries"; recon §6 shows a worked example). |

`Entry-v1` is exactly §7.2's: int-array payload, same `author`/`sequence`/
`timestamp` fields — NodeId and Hlc representations are identical across
both v1 dialects (recon §6).

**Payload signedness — the deployed emission is signed.** The deployed
server encodes each payload byte with Kotlin's sign-extending
`Byte.toInt()` (`SyncMessageCodec.kt:193`), so bytes `0x80`–`0xFF` reach
the wire as `-128`–`-1`. The committed golden fixtures are the ground
truth here (`deltaresponse.frame` carries `"payload":[0,1,127,-128,-1]`),
and they pin what every deployed app's translator actually receives.
§7.2's rule therefore applies unchanged to this dialect: upgraded kt
**emission** normalizes to unsigned `0`–`255` (accepted by every deployed
receiver — kt's own decode does `.int.toByte()`, old Dart's does
`cast<int>()`), every v1 **decoder** accepts `-128`–`255` and normalizes,
and only values outside that range are rejected. The existing goldens stay
byte-identical and become decode-side vectors; the unsigned emission gets
its own vectors (§8c).

No v1-kt frame carries `hasMore` — continuation stays v2-only. A v1-kt
DeltaResponse MAY additively carry `floor`, structured per (channelId,
streamId) alongside the existing nested `entries` map (owner decision
2026-08-29, §11 decision 3), mirroring set 1's v1-dart-flat addition (§8c)
so compaction interop works across the app↔server link before the fleet
reaches v2.

**`floor` and `hasMore` are a kt domain-model change, not a codec key
addition.** kt's `DeltaRequest`/`DeltaResponse` carry only `sender` plus
the nested maps — there is no field for either. Implementing §6.1 touches
`sync/domain/messages/` and every construction and consumption site, not
just the codec.

No Dart receiver is ever required to accept these shapes: the only link
they cross is the app↔server WebSocket, where the translator converts them
to/from v1-dart-flat (§4 rule 2).

---

## 8. Codec management and conformance vectors

*(Decision 7 — controller-chosen, open to veto.)*

Three legs, so that "which bytes does version N use?" always has exactly one
answer in each of: code, prose, and fixtures.

**(a) One codec module per wire version, behind a version-dispatching
facade — in each library.** Encode: the facade emits with the module the
`wireVersion` config selects. Decode: the facade sniffs byte 0 per §4 and
routes to the matching version module. In Dart this happens per context
(sync and membership each get a v1 and v2 module behind their facade,
preserving the family split and the boundary architecture — §4); in kt,
one facade over `ProtocolCodecV1`/`ProtocolCodecV2` (or the split-codec
equivalent if kt adopts Dart's context structure). No version's schema
knowledge leaks outside its module; adding v3 means adding a module and a
marker registration, touching no v1/v2 code.

**(b) A canonical wire-spec section per version.** §7 of this document
seeds it: §7.2 is the normative v1-dart definition, §7.4 the normative
v1-kt definition, §7.3 the normative v2
definition, §3.3 the marker registry. When a version is added or a field is
added within a version, this document (or its successor in a permanent docs
location) is amended in the same change. The prose spec is the tiebreaker
when the two codebases disagree.

**(c) Shared golden conformance vectors — the machine-checked leg.**
Canonical fixture files pairing exact frame bytes with their expected
decoded semantics, in **four sets**:

1. **v1-dart-flat** (§7.2): 7 message types, plus a **"v1+floor"**
   DeltaResponse emission variant (owner decision 2026-08-29, §11 decision
   3 — `floor` is additive on v1-send; the floor-less v1 decode vectors are
   unchanged, since deployed traffic never carries it), exercised by Dart's
   v1 codec modules and by the translator suite (set 3).
2. **v1-kt-batched** (§7.4): the kt-dialect types (PingReq with
   `originalRequester`, batched DeltaRequest/DeltaResponse, plus the shared
   0/1/3/4), plus the matching **"v1+floor"** DeltaResponse variant
   (§11 decision 3), exercised by kt's v1-kt codec module and by the
   translator suite. This set carries **both** payload signedness forms:
   the committed goldens (signed elements — the deployed server's
   emission) become decode-side vectors, and the unsigned-emission frames
   are pinned encode-side (§7.4).
3. **Translator round-trip suite:** pins OpenDoorApp's `ProtocolTranslator`
   against sets 1 and 2 — `translateOutgoing` maps each v1-dart-flat delta
   vector to its batched v1-kt counterpart, `translateIncoming` fans each
   batched vector out to the expected flat frames, and prefixed v2 frames
   pass through untouched (§5.3 step 5). The suite also pins the
   translator's new `floor` mapping (§11 decision 3): both directions carry
   `floor` across the flat↔batched reshape using the "v1+floor" vectors
   from sets 1–2, so server-side compaction interop is proven end-to-end
   before v2. This suite **lives in OpenDoorApp's tests**, not in either
   library repo, because the shim is app code; it consumes the same
   fixture files so the three codebases cannot drift apart silently during
   the migration window.
4. **Shared v2 set** (§7.3): 7 message types, identical bytes required of
   both libraries' v2 codecs.

Plus negative vectors: unknown marker, reserved bytes, empty
frame, malformed payload, legacy int-list payload inside a v2 frame,
a legacy payload byte **outside `-128`–`255`** (e.g. `300` — the only
out-of-range case; a negative element in `-128`–`-1` is a POSITIVE vector
that must decode and normalize, since it is what the deployed server
emits), v1 DeltaResponse decoded under v2 defaults. The fixture files live in the Dart repo — seeded from the existing inline
wire-pinning tests the recon located (recon §5:
`sync_message_codec_test.dart:405-560`,
`membership_message_codec_test.dart:48-`), which today are hand-copied
literals inside test files with no on-disk fixtures. The vectors are
**vendored into gossip-kt** with a checksum-pinned sync test: kt's build
fails if its vendored copy's checksum differs from the pinned value, so
drift between the repos cannot pass CI silently. Both libraries' codecs
must round-trip the identical vectors: decode the fixture bytes to the
expected semantics, and encode the semantics back to the exact fixture
bytes (byte-exact encode requires the vectors to fix JSON key order to
each encoder's natural emission order; if the two languages' JSON writers
cannot agree on ordering/spacing, the encode-side check relaxes to
"decodes back equal + length-bounded", decided at implementation time and
recorded in the vector README). This closes the recon's finding that
**gossip-kt has zero cross-language conformance tests today** (recon §5).
Fixture format (suggestion, not mandate): one JSON file per
version/message-type pair, frame bytes as base64, expected semantics as a
language-neutral JSON description.

---

## 9. Failure modes and misconfiguration

*(Decision 6's constraint, restated as observable behavior.)*

**A v2 frame reaching a not-yet-upgraded v1 Dart node (deployed pin):**
both engine codecs throw `ArgumentError('Unknown message type: 242')`, so
the node emits **two** `PeerSyncError(messageCorrupted)` reports per frame
— once labelled a gossip message, once a SWIM message (recon §1b). This is
noisy but non-fatal: the frame is dropped and the receive loop survives.
The systemic effect is worse than the noise: if a peer sends *everything*
in v2, the v1 node decodes none of its acks, so SWIM eventually declares
that peer dead — the fleet partitions by dialect. Misconfiguration is
therefore loud on v1 Dart nodes (error stream) and visible in membership
(peers flapping/dead), but never corrupting.

**A v2 frame reaching today's (pre-fix) gossip-kt — i.e. the deployed
server:** silent `null`, no log, no error, no trace (recon §2b/§2f) — the
node just doesn't sync.
This undiagnosable mode is itself a load-bearing reason decision 5 (§6.2)
is in scope: after the fix, a misconfigured sender shows up in kt's error
reporting instead of as mystery non-convergence.

**A v2 frame reaching an old (pre-upgrade) app over the WebSocket link:**
the old app's translator understands only batched v1-kt from the server —
a prefixed frame passes through untranslated and the app's engine codecs
then report it as an unknown type byte, exactly the v1-Dart-node case
above: per-frame error noise and effective partition of that link. This is
why §5.3 step 7 gates the server's v2 flip on *every* served app being
v2-receive-capable.

**Per the send-gating rules, neither the deployed v1 app nor its translator
ever sees a prefixed frame:** the app only gossips with peers that are
either v1-sending by default (steps 1–5 of §5.3) or flipped to v2 only
after the whole fleet — including it — was upgraded (step 6), and the
server stays on v1-kt-send until step 7's gate is met. The failure modes
above only arise if that ordering is violated.

**Reserved-byte frames (`0x07`–`0xEF`, `0xF0`–`0xF1`, unregistered
`0xF3`–`0xFE`, `0xFF`) on upgraded receivers:** reported decode error,
frame dropped, loop survives — same contract as any corrupt frame, in both
libraries (§4 rule 4).

**Transports:** no failure modes added. gossip_nearby's envelope byte and
gossip_bluey's length-prefix framing neither inspect nor collide with the
marker position (recon §4a/§4b); an unknown *outer* envelope byte in
nearby remains its existing logged-and-dropped behavior
(`connection_service.dart:494-496`), untouched by this design.

---

## 10. Out of scope

*(Decision 8 — controller-chosen, open to veto.)*

- **Message size caps and budgeting behavior.** The Dart side's
  version-awareness IS in the wire batch: a v1-mode sender must budget with
  v1's encoded sizes (int-array payloads are ~3.6 chars/byte vs base64's
  ~1.33 — recon/inventory item 12), so `maxEntryPayloadForBudget` and
  entry-size estimation must come from the *active send codec*, not a
  hardcoded formula.

  **kt's digest budgeting and delta pagination are NOT in the wire batch**
  (reassigned 2026-08-29): they belong to the port campaign's post-KT-B
  engine work. Three reasons. (1) kt has no deployed transport ceiling
  forcing them — the server speaks WebSocket, not a 32KB-framed radio, so
  nothing is broken while they are absent. (2) Budgeting is engine
  behavior, entangled with `hasMore` emission and pull tracking, not codec
  behavior; landing it inside a codec batch would mix two review surfaces.
  (3) The asymmetry is safe on the wire: kt honors a received
  `hasMore: true` with a continuation request, and truthfully sends
  `hasMore: false` because it always answers with a complete delta. A
  Dart peer that truncates is therefore drained correctly by a kt peer
  that does not.
- **Transport framing.** gossip_nearby and gossip_bluey are unaffected:
  the marker lives at the front of the inner payload both transports treat
  as opaque (nearby strips its own envelope byte before the core codec
  ever sees the frame; bluey never reads payload bytes at all —
  recon §4a/§4b). No transport-package change is part of this work.
- **Runtime version negotiation.** Deferred with its future shape sketched
  in §5.1; explicitly not designed here.
- **Batch envelope (future).** kt's batching insight — amortizing envelope
  overhead by carrying many streams' deltas in one frame — is real, and the
  Dart roadmap independently wants wire coalescing
  (`docs/backlog/engine-message-coalescing.md`). The future shape is a
  budget-aware aggregate: one frame carrying multiple per-(channel, stream)
  sub-messages, filled toward the wire byte budget (the same ceiling that
  drives today's per-stream truncation), preserving per-stream
  `hasMore`/solicited/`floor` semantics and giving each sub-message decode
  isolation (one corrupt sub-message is reported and dropped without
  killing the frame — unlike v1-kt's batching, where one bad entry nulls
  the whole message, recon §2c). It would arrive later as an additive
  message type within v2 or as v3 via the marker machinery (§3.3), with
  its own vectors. **Owner decision (2026-08-28): flat now, envelope
  future** — v2 ships the flat per-(channel, stream) schema, and this
  sketch is a recorded consideration, not scoped work.

---

## 11. Decision record (owner-ruled, 2026-08-29)

The three open questions this section used to pose were owner-ruled on
2026-08-29, and a fourth ruling (decision 4) was added the same day with
the amendments. This replaces the "open questions" framing; all rulings
are normative and are cross-referenced from §5.1, §5.3, §7.2, §7.4, and §8
wherever they touch a config default, a wire schema, or the conformance
vectors.

**1. Config surface.** An enum — `WireVersion.v1` / `WireVersion.v2` — on
each library's coordinator config (Dart: `wireVersion` on
`CoordinatorConfig`; kt: the equivalent field on its coordinator config).
Default is **`.v1` in BOTH libraries**. The deployed kt server does not get
a different library default to reach v2-send early; instead it flips to
v2-send explicitly at deploy time, once its gate (§5.3 step 7 — every
served app is v2-receive-capable) is met, exactly as §5.3 already
sequences it. Whether the *library* default itself ever flips from v1 to
v2 is **deferred to the ≥3.0.0 pub.dev publish decision** — it is not
scheduled by this spec and carries no target date.

**2. Vector vendoring.** The canonical vector set lives in the Dart repo
(`packages/gossip/test/wire_vectors/` or similar). gossip-kt carries
checked-in copies under its test resources, plus a committed content-hash
manifest. A kt test recomputes hashes over the locally vendored copies and
compares them against the manifest, so drift between the two repos fails
the kt build — this is the checksum-pinned sync test §8c already requires;
the vendoring mechanics are now settled rather than open. Updates to the
vectors are a deliberate act — re-copy the files into kt, then regenerate
the manifest — never an automatic sync. Promotion to a shared repo (a
third location neither library owns) is out of scope unless and until a
third implementation of the wire protocol appears.

**3. v1-send emission of `floor`.** YES — v1-send DeltaResponse emits the
additive `floor` field. Compaction working before the fleet reaches v2 is
a priority: upgraded peers get the late-joiner floor benefit while still
v1-sending, and old peers provably ignore the unknown key (recon §1c, §2e;
§7.1). `hasMore` is unaffected by this ruling and **stays v2-only** —
continuation already degrades gracefully without it (§7.2), so there is no
equivalent payoff to including it in v1.

**Consequence (owner-accepted):** the app's `ProtocolTranslator` gains one
new mapping — carrying the `floor` field across the app↔server WebSocket
link's flat↔batched reshape — so server-side compaction works end-to-end
even before the fleet reaches v2. This is a small, deliberate addition to
the shim, and it dies at v2 along with the rest of the translator (§5.3
step 8). The conformance matrix gains a **"v1+floor"** emission variant in
both the v1-dart-flat and v1-kt-batched vector sets (§8c) — the
pre-existing v1 DECODE vectors are unchanged, since old deployed traffic
never carries `floor`; the new variant is emission-side only.

**4. kt's `PingReq.originalRequester` is dropped at v2.** The field exists
only in the v1-kt dialect: Dart never had it, and kt's engine only ever
sets it to the local node — the same value it puts in `sender`
(`FailureDetector.kt:491`) — while its only read treats it as the node to
answer, which is that same sender (`FailureDetector.kt:321`). Reading
`sender` is therefore behavior-identical, and the deployed translator
already injects `originalRequester = sender` on every frame it forwards.
So: the **v2 schema omits the field entirely** (kt's v2 PingReq is Dart's
exact 3-key form, as byte-identical emission requires), kt's **domain
message drops it** and the detector reads `sender`, and kt's **v1-kt
emission keeps emitting it** — always equal to `sender` — for deployed
compatibility, with decode tolerating its absence. Carrying it forward as
an additive v2 key was rejected: it would make kt's v2 frames differ from
Dart's for a value the receiver can already derive.
