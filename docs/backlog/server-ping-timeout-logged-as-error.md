# Log a phone's ping timeout as the disconnect it is, not as a handler failure

**Track:** Server   **Depends on:** nothing

## What this is

When a phone stops answering the WebSocket's keep-alive pings — because it
went into airplane mode, lost signal, or was put to sleep — the server closes
its socket. That is an ordinary disconnect, and the server already logs it as
one ("Client disconnected"). But the same event is also logged a second time,
one line later, as an error: "Websocket handler failed", with a full stack
trace ending in "Ping timeout". Nothing failed; the handler ended the way a
handler ends when the other side stops talking.

## Why it matters

Errors in the production log are how a real fault gets noticed. Every phone
that walks out of range or sleeps produces one of these, so on a normal day
the error channel fills with disconnects and a genuine handler failure has
nothing to stand out against. It also misleads whoever reads the log for an
incident: the 2026-09-29 validation run of the round-wake bump produced
exactly one error, and it was a phone doing what phones do.

## Rough approach

Where the WebSocket route catches what ends a session, treat the framework's
ping-timeout close (an `IOException` whose message is the ping timeout) as a
disconnect: log it at INFO alongside the existing "Client disconnected" line,
with no stack trace, and keep ERROR with a stack for anything else. Pin it
with a test that times a session out and asserts the log holds no error.

## Related

- Seen on the live-device validation of opendoor-api PR #33 (2026-09-29): one
  phone's airplane-mode disconnect at 12:01:39, logged as
  `ERROR Application - Websocket handler failed … java.io.IOException: Ping timeout`.
- The reconnect side of the same event is the app's:
  the OpenDoorApp backlog item on reconnecting when connectivity is restored.
- Sibling: [Small follow-ups from the inbound-queue design audit](server-audit-follow-ups.md).
