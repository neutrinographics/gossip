# Treat creating or joining a channel as news

**Track:** Sync engine   **Depends on:** nothing

## What this is

Creating a channel locally, or joining one, is not recorded as news on
either twin. News (a merge, a local write, a pull in either direction, a
peer change) resets the quiescence pacer and wakes the sleeping round; a new
channel does neither. A pair whose pacer has backed off therefore announces
the new channel only at the next backed-off round, however recently the
channel appeared.

Observed in the Dart half of digest scoping: in
`integration/sync/digest_scoping_test.dart`, the join scenario takes about
14 simulated one-second rounds before the new channel is announced and
learned. The production figure on the Kotlin side was far better (a join
converged 0.4 s after the server created the channel) only because that
server had traffic keeping the pacer awake; a quiet pair waits.

## Why it matters

A user who joins a group on a quiet pair sees nothing converge until the
pacer's next wake, which at the ceiling is the idle interval, not the active
one. The cost of fixing it is one reset, and the cost of not fixing it is a
join that looks broken.

## Rough approach

Treat local channel creation as news: when the engine's channel set gains a
channel (`setChannels` on the Dart engine, the equivalent on the Kotlin
engine), call the same `recordNews()` that a local write calls, which resets
the pace and wakes the scheduler. Both twins, with a pin: a backed-off pair
announces a freshly created channel within the active interval.

## Related

- [Digest scoping](engine-scope-digests-to-shared-groups.md), whose join scenario observed it.
