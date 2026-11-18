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
`integration/sync/digest_scoping_test.dart`, the join scenario took about
14 simulated one-second rounds before the new channel was announced and
learned. That figure was measured before the recency-window fix (gossip
PR #22), which most likely closed most of the gap on its own; measured
again on this branch, the group converges at round 2 with the change and
round 3 without. The production figure on the Kotlin side was far better (a join
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

## Done

Built on branch `claude/project-thread-22tuwp` in both twins, 2026-11-18.
Both engines expose `notifyChannelCreated(channelId)`, shaped like
`notifyLocalWrite`: it does nothing unless the engine is running, and
otherwise records news. The Dart coordinator calls it from `createChannel`
after the channel map is refreshed; the Kotlin coordinator calls it from its
event handler when a channel is created. Creating a channel that already
exists and removing a channel are not news, and pausing is not either;
resuming already is, since a restart resets the pace. The
effect that remains, and is pinned on both twins: on a deeply idle pair,
creating a channel snaps the interval back from the idle ceiling (about 30
seconds) to the active band (5 seconds or less), so the new channel is
announced within the active interval instead of the idle one. Both twins' pins
also show that the first request after creation names the new channel. The
join scenario's round cap is a loose guard, not a measure of the win.
Design: [digest scoping leftovers](../superpowers/specs/2026-11-18-digest-scoping-leftovers-design.md).

## Related

- [Digest scoping](engine-scope-digests-to-shared-groups.md), whose join scenario observed it.
