# 0010: The home view reads each Alertmanager, and checks what reached Achtung

- Status: accepted
- Date: 2026-11-09

## Context

The user wants a home screen in the client: one tile per configured Alertmanager (onprem,
cdx, dat, …) saying what it has open, plus the active silences, the noisiest alerts and
the ones firing longest. They also want to see when the pipeline into Achtung is broken.

Achtung's database doesn't know what an Alertmanager has open. Achtung's webhooks are
extra `webhook_configs` inside existing Teams receivers, so Alertmanager sends Achtung
only the alerts routed to those receivers. A null-routed alert (the Watchdog, usually)
never arrives. A silenced or inhibited alert sends nothing, and neither does its resolve
(ADR 0008). A delivery can also just fail. Counting firing occurrences would show what
Achtung got, not what is wrong.

## Decision

- **`GET /api/home`** returns one entry per configured Alertmanager (`ALERTMANAGERS`),
  by instance name, plus the active silences, the noisiest alerts and the longest firing
  ones. The user approved the shape.
- **The counts come from each Alertmanager** (`GET /api/v2/alerts`), not from Achtung's
  database. `open` counts alerts that notify (state `active` or `unprocessed`) by
  `severity` label; an unknown or missing one is `other`. `silenced` counts suppressed
  alerts with a silence, and `inhibited` counts the ones only inhibited, so an alert both
  silenced and inhibited is counted once, as silenced. `Watchdog` and `InfoInhibitor`
  fire all the time by design, so no count includes them (since ADR 0011, a list of
  ignored alert names, shared and editable, seeded with these two and
  `grafana-irm-heartbeat`). `watchdog` says whether a
  `Watchdog` alert is there in any state: when it is absent, the alerting pipeline
  upstream of Alertmanager is broken.
- **Reads are cached like silences** (ADR 0008): each instance's alerts are read at most
  every 30 seconds, one read at a time. When a read fails, the entry says so
  (`reachable`, `error`) and keeps the last
  read that succeeded, with its time (`checkedAt`); before any has, its fields are null.
  `error` never contains the URL or credentials, nor the body of an error response (it
  can be a proxy's page naming hosts): only a code or the HTTP status. The log gets the
  body.
  The silences come from the same cache as `silencedUntil`, so the home view adds no
  second way to read them.
- **Achtung records which receiver feeds each channel.** An Alertmanager webhook names
  its `receiver`. A source adapter now passes the sender's name for what sent a
  notification (`receiver` in `SourceAdapter`'s result; null for a source without one),
  and ingest stores it on the channel (`channels.receiver`), updating it when it changes.
  The core stays source-agnostic: it stores a name, and only the delivery check gives it
  Alertmanager's meaning.
- **The delivery check compares the two** and reports per instance. Since ADR 0011, an
  alert with an ignored name is in neither of its lists. It compares firings, not
  alerts: an Alertmanager alert matches an occurrence when both its fingerprint and its
  `startsAt` do, as an occurrence's identity does (ADR 0007).
  - `missingInAchtung`: alerts that notify, are routed to a receiver some channel of that
    instance has recorded, started over 10 minutes before the read, and have no firing
    occurrence on that instance. Alerts routed only elsewhere are not expected, so a
    null-routed alert is never "missing". An occurrence with an event after the read
    (one that resolved since, say) counts as delivered: the read is too old to judge it.
  - `staleInAchtung`: occurrences firing in Achtung on that instance that Alertmanager no
    longer has in any state, last notified over 10 minutes before the read. These are
    resolves that never arrived, e.g. one suppressed by a silence, also when the alert
    has since fired again with a new start.
  - The 10 minutes cover `group_wait` and `group_interval`: a notification can be that
    late without anything being wrong. Both sides are measured against the read's time,
    not the request's, so a read kept while Alertmanager is down doesn't make everything
    since look stale or missing.
- **Nothing is reconciled automatically** (superseded by ADR 0014, which resolves
  occurrences that stay gone from their Alertmanager). The check only reports. Resolving a stale
  occurrence would invent an event Alertmanager never sent, with a guessed time, and a
  wrong comparison (a misconfigured receiver, a renamed instance) would silently rewrite
  history. The user decides what to do.
- **The noisiest alerts and the longest firing come from Achtung's database:** the 10
  alerts with the most `fired`, `reopened` and `resent` events in the last 24 hours (at
  least 2), each as its newest occurrence, and the 10 firing occurrences that started
  first. A new index on `events.recorded_at` keeps the first a range scan instead of a
  scan of the whole, ever-growing history.

## Consequences

- **The home view costs one alerts request per instance per 30 seconds**, on top of the
  silences, whatever the number of clients.
- **A channel knows one receiver, the last that delivered to it.** If two receivers send
  to the same channel, the other's alerts can show as missing until it next delivers.
  Each receiver should have its own channel URL, which is the usual setup.
- **A channel learns its receiver from its next notification.** Until every channel has
  received one after this change, alerts routed to a not-yet-recorded receiver are not
  expected, so the check under-reports at first, never over-reports.
- **The delivery check can be wrong in known ways:** a delivery older than 10 minutes
  still retrying, an alert routed to Achtung's receiver through a route with a long
  `group_wait`, or an alert that resolved and fired again between two reads. It is a hint
  to look, not a verdict.
- Stale occurrences stay firing until Alertmanager sends their resolve or someone deals
  with them. Superseded by ADR 0014, which resolves them using this check.
- Adding the column and the index is a plain migration (`0005_channel_receiver`). Building
  the index briefly blocks writes to `events` during the deploy.

## Addendum (2026-11-09): the alerts behind a tile

Clicking a tile in the client lists that Alertmanager's alerts, so the server has
`GET /api/alertmanagers/{instance}/alerts`. It adds no read: it takes the same cached
`GET /api/v2/alerts` read as the tile (30 seconds, one at a time, the last good read kept),
so the list and the counts can't disagree. Each alert stands where the counts put it
(`active`, `silenced` or `inhibited`, from one shared function), without Watchdog and
InfoInhibitor (since ADR 0011, without the ignored alert names); a suppressed alert that
is neither silenced nor inhibited (muted by a time interval) is in no count, so it isn't
listed either. `occurrenceId` matches the firing
like the delivery check does (fingerprint and `startsAt`, ADR 0007); when two channels of
the instance have the firing, the lowest id wins. `silencedUntil` comes from the silences
cache by the silence ids Alertmanager names, so it is null while that cache hasn't seen
the silence yet.
