# Carry stack traces with reported errors

**Track:** Code health   **Depends on:** nothing

## What this is

When the library reports a failure through its error callback, the error object
carries a message, a timestamp, and the underlying cause — but not the stack
trace of where the failure happened. The trace exists at every catch site, and
recent work made sure it is passed along internally, but there is nowhere for
it to go: the error type has no field for it, so on the normal reporting path
it is dropped before the application ever sees it. Today the only place a
trace survives is a narrow fallback used after shutdown, where errors are
routed to the logging callback instead.

## Why it matters

An application debugging a failure in the field gets "what went wrong" but not
"where" — the single most useful piece of diagnostic context. For a
peer-to-peer library where failures often surface far from their cause (a
storage error during a background merge, a transport error inside a scheduled
round), the trace is frequently the difference between a fixable bug report
and an unreproducible mystery.

## Rough approach

Either add an optional stack-trace field to the error type (a small, additive
API change — every reporting site already has the trace in hand), or route
errors through the logging callback on the live path as well, which already
accepts a trace. The field is the cleaner fix: it keeps one reporting channel
and lets applications decide what to do with the trace.

## Related

- Recorded as an observed limitation in the 2026-08 audit record's Batch H
  section: traces are threaded to every reporting site but evaporate at the
  error object's boundary.
