# 0007: An alert has a stable identity, and its occurrences are its history

- Status: accepted
- Date: 2026-11-08

## Context

The same alert fires again and again: a disk fills up every week, a job fails every
night, a service flaps. Alertmanager resends a firing alert every `repeat_interval` and
gives each new firing a new `startsAt`. A chat channel shows each of these as an
unrelated message. Achtung is meant to show them as one alert with a history, and later
features need that grouping as their foundation: flapping detection, "fired 6 times this
week", time to resolve, and state that belongs to the alert rather than to one firing
(notes, muting, acknowledgement across firings).

This was built from the start (see "Alert identity and lifecycle" in
`docs/architecture.md`). This ADR records it as a decision that other features may rely
on.

## Decision

- **An alert is identified by `(source, channel, sourceKey)`.** The channel includes its
  instance (ADR 0006). For Alertmanager, `sourceKey` is the `fingerprint`, a hash of the
  alert's full label set.
- **An occurrence is one firing of an alert: `(identity, startsAt)`.** The database
  enforces it with the unique constraint `occurrences_identity`.
- **Ingest deduplicates on that key.** A repeat notification updates the occurrence it
  belongs to and is never new. A firing with a new `startsAt` is a new occurrence of the
  same alert.
- **Occurrences are kept, and the alert's history is part of the API.**
  `GET /api/occurrences/{id}` returns the occurrence's events and up to 20 of the alert's
  other occurrences, newest first, which the client lists under "Earlier occurrences".
- **Every source adapter must provide a `sourceKey` that stays the same across firings
  of the same alert** and differs between different alerts. It must not contain
  anything that changes from one firing to the next, such as a timestamp or a delivery
  id.
- **The identity does not cross channels.** The same labels in two channels, or from two
  instances, are two alerts.

## Consequences

- **Features built on alert history can rely on this key.** Changing what makes two
  firings the same alert needs a new ADR and a data migration, because it rewrites
  history.
- **Labels decide what one alert is.** A label that changes on every firing (a pod name
  with a random suffix, a CronJob run's name) makes each firing a separate alert with no
  history. Grouping by chosen labels instead of the full label set would be a new
  identity rule, decided in its own ADR. The usual fix is in the alert rule: drop
  volatile labels or aggregate over them.
- **There is no `alerts` table.** The identity lives as columns on `occurrences`. State
  that belongs to the alert rather than to one occurrence will need a table keyed on the
  identity.
- **History is unbounded until there is a retention policy** (see the README's open
  questions). Retention must keep enough occurrences per alert for the features built on
  it.
- History starts when an alert first reaches Achtung. Firings from before that are not
  there, and neither are firings delivered to a different channel (a new URL, a typo, or
  the old-URL split described in ADR 0006). Moving or renaming a channel row keeps its
  history.
