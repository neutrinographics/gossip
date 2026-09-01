# Make stopping a Kotlin coordinator actually stop it

**Track:** Kotlin port   **Depends on:** nothing

## What this is

A device running the library can be started, paused, stopped, and started
again — a phone that goes to sleep and wakes up, a server that is taken out
of rotation and put back. Starting sets up two things: a background loop
that periodically reaches out to other devices, and a subscription that
listens for messages arriving from them.

In the Kotlin library, stopping only ends the first of those. The listener
is never cancelled — nothing tears it down short of disposing the
coordinator entirely. Two consequences follow, both confirmed by
reproducing them:

- A "stopped" device is not stopped. It keeps receiving messages from its
  peers and keeps merging their data into its own store, because nothing
  anywhere in the receiving path checks whether the device is supposed to
  be running.
- Every stop-and-start cycle adds another listener on top of the ones
  already there. After a couple of restarts, several listeners process the
  same incoming message and race each other to write the same data,
  producing real failures.

The Dart library has two separate defences the Kotlin one has neither of.
It owns its listener explicitly and cancels it when listening should stop.
And it separately gates *absorbing new data* on whether the device is
actually running, so that a paused device can still answer other devices'
questions without taking anything in — its own comment explains that a
paused device drops incoming data and relies on the normal catch-up
mechanism to re-fetch it after resuming.

## Why it matters

"Stop" is a promise to the application that the library will stand still.
An application that stops a device to save battery, to take it out of
rotation, or to stage a controlled handover gets none of that: the device
keeps doing the expensive half of the work invisibly. Worse, the duplicate
listeners turn an ordinary restart — the most routine lifecycle event there
is — into a source of genuine write failures, which is exactly the kind of
fault that looks like data corruption in the field and is very hard to
trace back to its cause.

It also means the two libraries disagree about what pausing means, which
matters because they are meant to be two halves of one system.

## Rough approach

The fix has two halves, and doing only the first is not enough. First,
give the coordinator ownership of its listening subscription so that
stopping cancels it and starting establishes a fresh one — the same
separation the Dart library already draws between "listening" and
"scheduling rounds". Second, port the Dart rule that absorbing incoming
data is part of active work: the receiving path needs to check whether the
device is running before merging, so that a paused device stays responsive
without taking data in.

Because this changes what the lifecycle methods promise, it deserves its
own written plan rather than riding along inside other work.

There is a ready-made acceptance suite: six scenarios from the Dart test
suite — three covering restart and recovery, three covering pause, resume,
and repeated start/stop cycles — were deliberately left untranslated during
the scenario batch precisely because they cannot pass against this defect.
Translating them is the proof the fix works.

## Related

- Recorded with the full mechanism and file-level evidence in the
  twin-divergence register:
  [Record where the Dart library and its Kotlin twin diverge, with a verdict](kt-normalize-twin-divergences.md).
- Found during the correctness-and-scenarios batch of
  [Teach both libraries to speak versioned wire formats](kt-wire-versioning-campaign.md).
- The six blocked scenarios are also noted in
  [Sweep the remaining scenario coverage into the Kotlin library](kt-scenario-parity-sweep.md).
- Sibling defect found in the same batch, since ruled a retirement whose
  Kotlin half this item's batch absorbs:
  [Retire indirect health probing from both libraries](kt-retire-indirect-probing.md).
- Worth folding in while restructuring these call sites:
  [Stop the Kotlin library from treating cancellation as a failure](kt-cancellation-swallowed.md).
