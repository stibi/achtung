# 0016: Silence several of an Alertmanager's alerts from its tile

- Status: accepted
- Date: 2026-11-10

## Context

A Home tile opens a list of the Alertmanager's alerts (ADR 0010). The user wants to
silence all of them, or a selection, for a chosen time, right there. Some of those alerts
are not in Achtung at all (routed only to other receivers), so they have no occurrence
to silence through `POST /api/occurrences/{id}/silence` (ADR 0008).

## Decision

- **`POST /api/alertmanagers/{instance}/silences` with `{fingerprints, durationSeconds}`**
  (1 to 500 fingerprints). The server reads the instance's alerts fresh, finds each by
  fingerprint, and gives each its own exact silence, as for one alert, changing one it
  already has rather than adding another (ADR 0015). The silences are read once for the
  whole request.
- **One silence per alert, not one broad silence.** A silence matching what the selected
  alerts share would also mute alerts that fire later, which nobody chose. Exact silences
  stay Achtung's to change and end one by one (ADR 0015).
- **The answer has one entry per fingerprint:** its `silencedUntil`, or an `error` for an
  alert that is no longer in Alertmanager, which is not silenced. A refusal or an
  unreachable Alertmanager fails the whole request (502); silences made before it stay, and
  a retry changes them rather than duplicating them.
- Afterwards the alerts cache is invalidated, so the tile's list and Home show the change
  on their next read.
- "Mark as read" there is the client's own (read state, ADR 0002): it marks the listed
  alerts that have an occurrence in Achtung.

## Consequences

- Silencing many alerts is one click away; the client must say how many alerts, and
  that the silences mute them for every receiver of that Alertmanager, before it does.
- A request makes one Alertmanager call per alert. A few hundred is fine for an
  Alertmanager; the limit of 500 keeps a request bounded.
- The silences' comment names the instance and the alertname; there is no user to name
  (ADR 0002).
