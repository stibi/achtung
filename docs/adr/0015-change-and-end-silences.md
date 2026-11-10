# 0015: Change and end an alert's own silence

- Status: accepted
- Date: 2026-11-10

## Context

Achtung creates a silence for exactly one alert (ADR 0008), but once silenced, the
alert could only be silenced again, which added another silence; the longest one won, so
a silence could be lengthened but never shortened or ended from Achtung. To unsilence,
the user had to find the silence in Alertmanager's UI. Silences made there for many
alerts at once (a maintenance window, a namespace) are a different thing: ending one
from a single alert would unmute every other alert it covers, out of sight.

## Decision

- **Achtung changes and ends only an alert's own silences:** those whose matchers are
  exactly the alert's labels, one equality matcher each, as Achtung creates them and as
  Alertmanager's "silence this alert" does (`isExactlyFor`). Broader silences are left to
  Alertmanager.
- **Silencing a silenced alert changes its silence** (`POST /api/occurrences/{id}/silence`,
  same request): the latest-ending exact silence gets the new end, sooner or later, through
  Alertmanager's update, a `POST` with its id. Alertmanager changes a silence in place only
  with the same matchers, in the same order, and, once it has started, the same start, so
  Achtung sends those back unchanged: the silence keeps its id, start and history. A
  silence that hasn't started yet is sent with Achtung's matchers and start now, and
  Alertmanager replaces it with a new one. Any further exact silences are ended, so the
  new end is the alert's. Without one, a new silence is created as before.
- **`DELETE /api/occurrences/{id}/silence` ends them now** (Alertmanager's
  `DELETE /api/v2/silence/{id}`, which expires it) and returns the occurrence. Its
  `silencedUntil` still shows a broader silence that mutes it, from the same read that
  decided what to end, so a failed re-read can't hide it. If only a broader silence
  does, nothing is ended and the answer is 409, saying to end it in Alertmanager. An alert
  without a silence is not an error.
- Both read the instance's silences fresh, not from the 30-second cache, so they see
  every silence there is, and invalidate the cache afterwards, as creating did.

## Consequences

- The client can offer "end silence" and "silence for … from now" on a silenced alert,
  and shortening works.
- A silence someone made in Alertmanager for exactly this alert is Achtung's to change
  too: by its matchers it is indistinguishable from Achtung's own, and changing it
  affects only this alert.
- Ending is not atomic: with several exact silences, a failure part way leaves some
  ended; the answer is 502 and a retry ends the rest.
- Updating keeps no record in Achtung of who changed what (ADR 0002); Alertmanager's
  silence keeps `createdBy: Achtung` and the comment.
