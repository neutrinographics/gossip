# Stop the Kotlin library from treating cancellation as a failure

**Track:** Kotlin port   **Depends on:** nothing

## What this is

When a coroutine — Kotlin's unit of concurrent work — is asked to stop, the
runtime signals that by throwing a special cancellation exception through
it. The rule that makes this work is that cancellation must be allowed to
travel: code that catches errors is supposed to let the cancellation signal
pass through rather than treat it as a fault.

Six places in the Kotlin library catch every exception, which in Kotlin
includes the cancellation signal. Two things go wrong as a result. The
signal is reported as if it were a real error — so shutting a device down
produces a spurious peer-communication error in the log — and the coroutine
that should have stopped instead carries on past the point where it was
cancelled.

## Why it matters

On its own this is a shutdown-path annoyance: a misleading error at the
moment a device is being torn down, when nobody is looking closely. It
matters more than that for two reasons.

The first is that the library now deliberately sends cancellation at those
exact places. The test harness cancels a device's simulated clock as part
of tearing a scenario down, and the only thing that stops that producing
mystery errors is that the harness carefully disposes the device *before*
cancelling its clock. That ordering is currently load-bearing for a large
number of tests and is documented only in a comment. The next person to do
it the other way round gets an unexplained error.

The second is that the library already does this correctly elsewhere — the
scheduler and the derived-view builder both let cancellation through. So
the codebase now carries two contradictory idioms for the same situation in
the same layer, and the wrong one is the more common.

## Rough approach

Mechanically, this is small: let the cancellation signal through before the
general error handler at each of the six sites, matching the idiom the
library already uses in the two places that get it right.

The reason it is written down rather than simply done is placement: several
of those sites sit inside the start-and-stop machinery that a separate
piece of planned work is going to restructure anyway, and that work needs
to decide the whole cancellation-and-shutdown contract at once rather than
inherit a half-changed version of it. Doing this alongside — or as part of —
that work is better than doing it in isolation.

## Related

- Best done with, or as part of,
  [Make stopping a Kotlin coordinator actually stop it](kt-coordinator-restart-lifecycle.md),
  which restructures several of the same call sites.
- Surfaced by the final review of the correctness-and-scenarios batch of
  [Teach both libraries to speak versioned wire formats](kt-wire-versioning-campaign.md).
