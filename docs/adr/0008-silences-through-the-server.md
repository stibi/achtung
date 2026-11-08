# 0008: Silences are created through the server, and Alertmanager says what is silenced

- Status: accepted
- Date: 2026-11-08

## Context

The README left open whether the client should create Alertmanager silences, and how,
given that Achtung has no authentication. The user wants a silence button on each alert
(1h, 4h, 1d, 1w). Each instance is one Alertmanager (ADR 0006), and Achtung is deployed
next to them on the operator's network. The client is only configured with Achtung's
address.

## Decision

- **The server creates the silence, on the occurrence's instance's Alertmanager:**
  `POST /api/occurrences/{id}/silence` with `{ "durationSeconds": 60..2592000 }`. The
  client never talks to Alertmanager.
- **A silence covers exactly this alert:** one equality matcher per label, as
  Alertmanager's own "Silence" button does. It matches labels, so it also covers a
  re-fire of the same alert (ADR 0007). It starts now, `createdBy` is `Achtung` (there are
  no users to name, ADR 0002), and the comment names the instance, channel and alert.
- **Alertmanager is the source of truth for what is silenced.** Achtung stores no
  silences. Every occurrence the API returns carries `silencedUntil`: the end of the
  latest active silence whose matchers match its labels, else null. That includes
  silences made elsewhere, for example in Alertmanager's UI, and silences expired early
  there. The server reads each instance's silences (`GET /api/v2/silences`) at most every
  30 seconds and evaluates the matchers itself, so a page of occurrences costs at most one
  request per instance.
- **Each instance's Alertmanager is deployment configuration:** `ALERTMANAGERS`, a JSON
  object of instance name → `{ url, username?, password? }`, set from a secret.
  Credentials inside the URL are rejected, and errors name only a code such as
  `ECONNREFUSED`, never the URL, so a password can't reach a log or a response. We did not
  use the `externalURL` in webhooks: it is often a pod address (ADR 0006), and it carries
  no credentials.
- **Errors:** 400 for a duration out of range, 404 for an unknown occurrence, 409 when the
  instance has no Alertmanager configured (or the alert isn't from Alertmanager), 502 when
  Alertmanager is unreachable or refuses the silence, with its reason.

## Consequences

- **A silence mutes the alert for every receiver of that Alertmanager**, not only for
  Achtung: Teams, the pager, email. The route's description says so, and the client should
  too.
- **Anyone who can reach Achtung's API can silence alerts** (ADR 0002). Protecting the
  network path to Achtung now also protects paging. Achtung itself holds Alertmanager
  credentials, so it must not be reachable from outside that network.
- **While an alert is silenced, Alertmanager does not send its resolve either.** A silenced
  alert that resolves can stay firing in Achtung, because the resolved notification may
  never be sent once the silence ends. Fixing it needs Achtung to reconcile with
  Alertmanager's alerts (`GET /api/v2/alerts`), which is a separate change.
- **Reads depend on the Alertmanagers being reachable, but never fail because of them.**
  When an Alertmanager can't be read, its last known silences are used, or none, until
  the next 30-second window; the server logs a warning. `silencedUntil` can then be stale
  or missing for that instance. A read that started before Achtung created a silence is
  discarded, so it can't hide the new silence.
- **Matching is Achtung's own evaluation of Alertmanager's matchers.** Regexes are
  anchored like Alertmanager's, but run as JavaScript regexes, not RE2. A matcher with a
  regex JavaScript can't compile (e.g. a leading `(?i)`) never matches, negated or not,
  so such an alert is shown as not silenced rather than wrongly silenced.
- Expiring a silence from Achtung isn't built; it is done in Alertmanager for now.
