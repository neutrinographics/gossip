# Serve a phone only the channels its user may read

**Track:** Server   **Depends on:** nothing

## What this is

The server holds a channel for every user and every group it knows. Today it
answers a request for entries from *any* channel a phone names, and the
sync-check route reports progress for any channel id likewise, with no check
that the phone's user belongs to that group or owns that account. Digest
scoping (2026-10-01) stopped the server *volunteering* every channel's
identifier to every phone; it does not stop a phone that already knows an
identifier from pulling that channel's entries.

This item adds the check: a phone may pull, and ask about, only the channels
its user may read — its own account channel and the groups it is a member of
— and anything else is refused and logged.

## Why it matters

Group identifiers travel in QR codes and were, until scoping, announced to
every nearby device. A phone with a leaked identifier can read a group it
was never admitted to. The server is the one place in the system that knows
who belongs where and can enforce it; the phones' nearby links cannot.

## Rough approach

The server already maps a connected phone to its user (from the hello
message, unverified today) and a user to its groups (from the linked-member
events it folds). Gate the delta-request and sync-check paths on that
mapping. Two things to decide first: whether the claimed user identity
should be verified before it is trusted for authorization, and what a
joining phone — which holds a group's channel before the server has folded
its membership — is allowed to pull during the join.

## Related

- Found during the [digest-scoping](engine-scope-digests-to-shared-groups.md) design (spec's "Recorded in the same docs pass").
- The identity the server keeps per connection: the session-ownership work in [Stop the server from talking to a phone's dead session after it reconnects](server-session-ownership.md).
