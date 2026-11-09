# 0011: Ignored alert names are a shared server setting

- Status: accepted
- Date: 2026-11-09

## Context

The Home view (ADR 0010) left `Watchdog` and `InfoInhibitor` out of each Alertmanager's
counts, a list hardcoded in `domain/overview.ts`. Other heartbeats fire forever too, e.g.
`grafana-irm-heartbeat`, and inflate the counts the same way. Which alerts are noise
depends on the deployment, so the user wants to edit the list from the macOS app.

## Decision

- **One list on the server, shared by every client.** It is stored in Postgres
  (`ignored_alert_names`: the name as primary key, and when it was added) and edited
  through the API: `GET /api/settings/ignored-alerts` returns `{ names }`, sorted, and
  `PUT` with `{ names }` replaces the whole list in one transaction and returns it as
  stored. A dedicated table, not a generic key/value bag: there is one setting, and a
  table of names needs no JSON parsing (golden principles 1 and 3).
- **Not per Mac.** The counts and the delivery check are computed on the server, and the
  same tile should read the same on every client; a per-client list would need the
  server to take it as a parameter on every request, or the client to recount. It
  follows ADR 0002: there are no users, so the list is not per person, and anyone who
  can reach the API can change it, as anyone can create a silence (ADR 0008).
- **Names are Prometheus alertnames, matched exactly and case-sensitively** against the
  `alertname` label, with no regex. An alert without one is never ignored. The `PUT`
  trims each name and stores a repeat once; it answers 400 for an empty name, one over
  200 characters, or over 200 names. The table is locked for each replacement, so two at
  once don't merge: the later one wins whole.
- **Scope: the Alertmanager-derived Home views only.** An ignored alert is in no count of
  `/api/home`, not in `/api/alertmanagers/{instance}/alerts`, and in neither delivery
  list: not `missingInAchtung`, and not `staleInAchtung`, also when it fires in Achtung.
  The inbox (channels, Live, the feed and the badges) still shows it: Achtung ignores
  only what it reads from Alertmanager, never what was delivered to it.
- **`watchdog` doesn't depend on the list.** It still says whether an alert named
  `Watchdog` is there, also while `Watchdog` is ignored: the heart is about the pipeline,
  the list about the counts.
- **Applied per request.** The pure functions in `domain/overview.ts` take the set as a
  parameter. The service reads it from the database for each request, a tiny query, and
  not with the cached Alertmanager read, so a `PUT` applies to the next request, even
  within the same 30-second read.
- **Seeded by the migration** (`0006_ignored_alert_names`) with `Watchdog`,
  `InfoInhibitor` and `grafana-irm-heartbeat`: a deploy keeps the old exclusions and adds
  the IRM heartbeat.

## Consequences

- Emptying the list counts `Watchdog` and `InfoInhibitor` as alerts again (`other`, as
  they have no known severity).
- Anyone who can reach the API can hide an alert from the Home counts of every client.
  The inbox still shows it, and the operator controls access in front of the app
  (ADR 0002).
- The macOS client gets a settings UI later, generated from the spec. Until then the list
  is edited with the API.
