# 0009: A resend of a firing alert resurfaces it, at most once an hour

- Status: accepted
- Date: 2026-11-08

## Context

Alertmanager resends an alert that is still firing: every `repeat_interval` (4h on cdx),
and whenever its group changes, e.g. another alert with the same `alertname` starts
firing. Until now a repeat updated the occurrence in place and was never news (ADR
0007's deduplication), so an alert that kept firing for hours vanished into the read
backlog. Teams showed it again with each resend, so the user saw alerts there that
Achtung didn't surface. The user wants a resend to count as unread again, shown
differently from a new alert. Achtung can't tell a `repeat_interval` resend from one
caused by a group change.

## Decision

- **A repeat of a firing occurrence records a `resent` event, if its last event was at
  least an hour ago** (`resendQuietPeriodMs` in `src/domain/occurrence.ts`). Within the
  hour it is a plain repeat, as before: fields are updated, nothing is recorded. The user
  chose hourly over every resend, so a busy group doesn't keep re-marking its alerts.
- A `resent` event moves `lastEventAt` like any event. The lists' order, paging and the
  client's unread state already key on `lastEventAt`, so a resent alert moves to the top
  and is unread again, with no change to how they work.
- **A resolved occurrence is never resent.** Alertmanager sends a resolve once.
- Every occurrence carries `lastEventKind`, what happened at `lastEventAt`, so a client
  can show a resend differently from a fire without loading events. `resent` is also part
  of the occurrence's history (`GET /api/occurrences/{id}`).
- A resend still isn't **new**: ingest's summary counts it in neither `new` nor
  `resolved`. Ingest stays idempotent: delivering the same notification twice records at
  most one `resent`, because the first moved `lastEventAt`.

## Consequences

- The events table grows by at most one row per firing occurrence per hour.
- An alert that fires for days resurfaces about every `repeat_interval`. Silencing it
  (ADR 0008) stops the resends, and so the resurfacing.
- The hour is a constant, not configuration. If it turns out wrong for some instance,
  make it a setting then.
- During the rolling deploy, a replica still on the old code doesn't set
  `last_event_kind`: an occurrence it resolves or reopens after a new replica recorded a
  `resent` keeps the old kind until its next event. An old replica also can't serve the
  history of an occurrence that already has a `resent` event. Both last only while the
  two versions run side by side.
- Adding `resent` to the event kinds changes a closed enum in the generated Swift client,
  so the client must be rebuilt with this server change.
