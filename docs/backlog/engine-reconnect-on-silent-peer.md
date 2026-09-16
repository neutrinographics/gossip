# Reconnect the transport when a peer stops answering gossip while the link stays up

**Track:** Sync engine   **Depends on:** nothing (best taken after the Dart half of
[retiring indirect probing](kt-retire-indirect-probing.md), which touches the same detector)

## What this is

A device's failure detector already notices when a peer stops answering
its probes and marks it unreachable. Today that verdict changes how the
device gossips, but nothing tells the transport underneath to do anything
about it. When the transport is a WebSocket to the server, the socket can
look perfectly healthy at the network layer, answering the server's
keepalive pings, while the sync layer above it hears nothing for an hour.
This item makes a prolonged silence from a peer, on a link that has not
dropped, a reason to reconnect that link.

## Why it matters

In the last meeting of 2026-09-16 one phone received nothing from the
server for 63 minutes (and 48 minutes earlier the same afternoon). The
cause was a server defect, fixed in opendoor-api release v48: the server
kept addressing a session the phone no longer had. But the phone had every
signal it needed to recover on its own within a couple of minutes: its
probes to the server went unanswered the whole time. A phone that
reconnects when a peer falls silent bounds any future defect of this
shape, on either side, to the silence threshold instead of the length of
the meeting. It is defense in depth, not the fix.

## Rough approach

The detector already has the "unreachable" transition. Give the
application a way to hear it with a duration attached, and let the app's
server transport respond to "the server has been unreachable for N
seconds while my socket is open" by closing and reopening the socket. Keep
the threshold well above a single missed probe, on the order of a minute
or two, so a slow round trip or a brief network stall never causes a
reconnect. Do not make the library reconnect anything itself; it does not
own transports. The Bluetooth transports may want the same hook later.

## Related

- Evidence: [the 2026-09-16 incident report](../audits/2026-09-16-last-meeting-incident.md), finding 1.
- The server-side cause it guards against: [session ownership](server-session-ownership.md).
- The detector work it should follow: [retire indirect probing](kt-retire-indirect-probing.md).
