# 0014: Resolve occurrences that are gone from their Alertmanager

- Status: accepted
- Date: 2026-11-10

## Context

Alertmanager doesn't send the resolve of an alert that resolves while silenced or
inhibited (ADR 0008), so it stays firing in Achtung. Home's delivery check (ADR 0010)
reports these as `staleInAchtung`, but deliberately left them alone. In production that
list keeps growing (13 on onprem, 4 on cdx, 5 on onepost at the time of writing): the
inbox, Live, the noisiest and longest-firing lists and the macOS menu bar count all show
alerts that ended long ago. The user asked Achtung to close them.

ADR 0010 named the risks of doing that: Achtung would record an event Alertmanager
never sent, at a guessed time, and a wrong comparison would rewrite history quietly.

## Decision

- **The server resolves what stays gone.** `services/reconcile.ts`, run by `main.ts`
  every minute (one run at a time), reads each Alertmanager through the shared 30-second
  cache (ADR 0010) and takes the same comparison as `staleInAchtung`
  (`goneFromAlertmanager`): an occurrence firing in Achtung on that instance, last
  notified over 10 minutes before the read, whose fingerprint and start the Alertmanager
  no longer has in any state. Ignored names (ADR 0011) count too: they are about what
  Home shows, not about the data.
- **Only after 5 minutes of successful reads without it** (`vanishAfterMs`). A
  restarted Alertmanager that lost its state learns its alerts from Prometheus again
  within a minute or two. A failed read, or one listing no alerts at all (every
  Alertmanager has its Watchdog firing, so an empty list means one that just started or
  isn't the right one), starts the count over for that instance. Absences live in memory,
  per instance; a restart of the server starts them over too. There is one replica.
- **It says so.** The occurrence gets `status: resolved`, `endsAt` the first read that
  didn't have it (the closest Achtung knows), and a `resolved` event whose new `cause`
  is `vanished`; events caused by a notification have `cause: null`. The API's `Event`
  gains `cause`, for a client to show as "gone from Alertmanager". `lastEventKind` stays
  `resolved`, so clients that don't know `cause` treat it as any resolve.
- **A notification wins.** The resolve is a conditional update of the row (still
  firing, `lastReceivedAt` unchanged since the read), so an ingest of the same occurrence
  in between keeps it firing. If Alertmanager later sends the alert as firing with the
  same start, ingest reopens it as it reopens any resolved occurrence (ADR 0007); a
  late resolve from Alertmanager only updates `endsAt`.
- Home's `staleInAchtung` stays as it is: it now shows the occurrences within their
  five minutes, and any an Alertmanager can't confirm.

## Consequences

- Stale occurrences close within about 16 minutes of their last notification (10 of
  delivery grace, 5 of absence, up to 1 of schedule) or 5 minutes after Alertmanager
  dropped them, whichever is later.
- **A misconfigured instance resolves everything of it:** an `ALERTMANAGERS` URL that
  points at another, non-empty Alertmanager makes all of the instance's occurrences look
  gone. They are marked `vanished`, so this is visible and traceable, and they reopen as
  soon as their Alertmanager notifies again (at its `repeat_interval`). The server logs
  each run's resolved ids.
- **The first deploy resolves the backlog at once**, about 5 minutes after start. Each
  resolve is an event, so those occurrences show as unread changes in the clients once.
- No extra Alertmanager requests: the reconciler shares the cache with Home.
- The new `event_cause` enum and the nullable `events.cause` column are a plain migration
  (`0007_vanished_events`). Old rows read as `cause: null`.
- ADR 0008's open "reconcile with Alertmanager's alerts" and ADR 0010's "Nothing is
  reconciled automatically" are settled by this ADR.
