# Cut redundant work on the message hot path

**Track:** Sync engine   **Depends on:** nothing

## What this is

A bundle of measured inefficiencies where the same bytes are decoded, encoded,
or looked up several times over on every message — all on the UI isolate,
and worst during catch-up when large sync pages arrive at link speed:

- **Every incoming message is fully decoded twice.** The sync engine and the
  failure detector each decode every message and discard what isn't theirs,
  even though the wire format starts with a type byte designed for cheap
  dispatch. Malformed input is even reported as corrupt twice.
- **Outgoing messages are encoded up to eight times.** Size checks encode,
  then sending re-encodes; a reactive push to several peers re-encodes once
  per peer instead of encoding once and reusing the bytes.
- **Any out-of-order merge rebuilds derived state from scratch.** Routine
  under concurrent multi-author writes; the rebuild refolds the entire stream
  inline in the merge path.
- **The BLE sender re-resolves the GATT service and characteristic for every
  chunk** — a 30 KB message is ~165 chunks (or ~1,540 at the smallest MTU),
  each repeating a lookup that was already done once at connection setup.

## Why it matters

Milliseconds and hundreds of kilobytes of garbage per large page, multiplied
across engines and peers, on the isolate that also draws the UI. These are
the deferred performance findings (PERF3-1, 2, 4, 5) from the 2026-07-08
audit — its round "R10".

## Rough approach

Dispatch on the wire type byte before decoding; let the send path accept
pre-encoded bytes (the ping-request path already shows the pattern); use
views instead of buffer copies; cache the resolved GATT characteristic per
link; for the rebuild, repair from a checkpoint or offer folds a
commutativity opt-in that keeps the incremental path.

## Related

- Findings PERF3-1/2/4/5 in
  [audits/2026-07-08-comprehensive-audit.md](../audits/2026-07-08-comprehensive-audit.md).
