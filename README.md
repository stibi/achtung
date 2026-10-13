# Achtung

A self-hosted alert inbox with a native macOS client.

> **Status:** early development. The server skeleton and the Alertmanager payload adapter
> exist. Ingest, storage, the client API and the macOS client don't exist yet. Open
> questions are listed at the end.

## The problem

I run, maintain and support a number of systems across several apps and environments.
Their Prometheus alerts are currently sent by Alertmanager to MS Teams channels. That
setup is bad to use and bad to run:

- **UI/UX.** The cards look bad, they are hard to scan, and you can't tell what is new.
  Firing and resolved alerts look almost the same. The client is slow.
- **Delivery.** Teams throttles incoming webhooks, so notifications arrive late or not
  at all, often during the busiest incidents.
- **Configuration.** Setting up connectors and workflows is fiddly and fragile.
- **Model mismatch.** Teams is a chat tool. An alert is not a chat message. It has a
  lifecycle (firing → resolved), an identity and labels, and it needs to be acknowledged.

## What Achtung is

Achtung replaces the "alerts in a chat channel" setup with a tool built for alerts:

- A **server** that receives alert notifications from monitoring systems by webhook,
  normalizes them, stores them and tracks their state. It serves an API to clients.
- A **native macOS client** for viewing alerts and working with them. UI and UX are the
  top priority.

It started as a tool for my own needs and is open source from the start. Anyone can run
their own instance.

## Core use case

1. Alertmanager fires an alert and POSTs it to an Achtung webhook. Each channel gets its
   own webhook.
2. The server stores the alert under the right channel. If it already knows the alert
   (same fingerprint), it updates it instead of creating a duplicate.
3. The macOS client shows the new alert right away, with an unread marker and,
   optionally, a system notification.
4. I open the app and see straight away **what is new since I last looked**, what is
   **still firing**, and what has **resolved**.
5. I acknowledge the alert, follow its links (Prometheus expression, runbook, dashboard)
   and move on. When the alert resolves, it updates in place and does not appear as a
   new message.

## Concepts

| Concept | Meaning |
|---|---|
| **Source** | A system that sends alerts. Alertmanager is the first one, and the design must allow others (Grafana, Uptime Kuma, GitHub, cron/backup jobs, custom scripts…). Each source has an adapter that converts its payload to the internal model. |
| **Channel** | A named stream of alerts, usually one per app or environment (`crm-prod`, `legal-machine-dev`, …). Each channel has its own webhook endpoint. |
| **Alert** | The normalized internal record. It has a stable identity (for Alertmanager, the `fingerprint`), a status (`firing` / `resolved`), severity, labels, annotations, timestamps, links back to the source, and the raw payload for debugging. |
| **Event** | Something that happened to an alert: it started firing, it resolved, it fired again, it was acknowledged. Events make up the alert's history. |
| **Read state** | What this client has already seen, per channel. It is stored locally in the macOS app and powers "new since last time". |

## Server

- TypeScript on Node.js, Fastify, PostgreSQL (see [ADR 0001](docs/adr/0001-tech-stack.md)).
- **Ingest:** one HTTP endpoint per source type, scoped to a channel, for example
  `POST /ingest/alertmanager/{channel}`. Ingest must be fast and
  idempotent, because Alertmanager retries and sends the same alert again every
  `repeat_interval`.
- **Source adapters:** each source is a module that validates its payload and maps it to
  the internal model. Adding a source should not require changes to the core.
- **Storage:** alerts, events, channels and read state.
- **Client API:** list and filter alerts per channel, alert detail and history,
  acknowledge. Server-Sent Events deliver new alerts and state changes to clients without
  polling.
- **Deployment:** a single container on Kubernetes, exposed through an ingress, with an
  external Postgres.

### Security model

Achtung has **no authentication and no users** (see
[ADR 0002](docs/adr/0002-no-authentication.md)). Everyone who can reach an instance sees
all alerts and can acknowledge them, and anyone who can reach the ingest endpoints can
post alerts. **Do not expose it to the internet unprotected.** Restrict the ingress to
your network or VPN, or put an authenticating proxy (oauth2-proxy, basic auth) in front
of it.

### Alertmanager specifics

Alertmanager's webhook sends a group notification (payload version `4`): `status`,
`groupKey`, `groupLabels`, `commonLabels`, `commonAnnotations`, `externalURL`, and an
array of `alerts`. Each alert has `status`, `labels`, `annotations`, `startsAt`,
`endsAt`, `generatorURL` and `fingerprint`. Achtung tracks individual alerts by
`fingerprint` and can still show the group context. See the
[Alertmanager webhook docs](https://prometheus.io/docs/alerting/latest/configuration/#webhook_config).

## macOS client

- Native, built with Swift and SwiftUI.
- **UX goals**, in priority order:
  1. **New since last visit is unmistakable.** Unread counts per channel and a clear
     marker on new items.
  2. **State is obvious at a glance.** Firing and resolved look clearly different, and
     severity is shown by color and position, not only by text.
  3. **Fast and keyboard-friendly.** It opens instantly, you can move through the list
     and acknowledge alerts with the keyboard, and search is quick.
  4. **Calm.** Repeat notifications for an alert that is already firing don't create
     noise. A resolution updates the existing item.
  5. **Good defaults over configurability.** The first goal is one very good default
     view. Customization comes later, if it's needed at all.
- A menu bar presence with an unread or firing badge, and optional macOS notifications.
- Layout: channels in a sidebar, then the alert list, then alert details (a standard
  three-column macOS layout).

## Non-goals (for now)

- Replacing Alertmanager's routing, grouping, inhibition or silencing. Alertmanager stays
  the brain, and Achtung is the inbox. Creating silences from the client may come later.
- On-call scheduling, escalation and paging (PagerDuty/Grafana OnCall territory).
- iOS, web or Windows clients. The API should not prevent them, but they are not planned.
- Multi-tenant SaaS, user accounts and login.

## Open questions

- **Notifications when the app is closed:** APNs push needs an Apple Developer account and
  a relay. Without APNs, system notifications only arrive while the client is running.
- **Retention:** how long resolved alerts and their history are kept.
- **Silences:** whether to create Alertmanager silences from the client, and how,
  given that the server has no auth.

## Development

Requirements: Node.js and pnpm (versions in `.tool-versions` and `package.json`). Docker
will be needed for the Postgres integration tests, and a Mac for the client.

```bash
pnpm install                  # dependencies and git hooks
pnpm --dir server run check   # all quality checks and tests
pnpm --dir server run dev     # run the server on :8080
```

The project is developed mostly by coding agents. Their rules are in
[`AGENTS.md`](AGENTS.md) (`CLAUDE.md` is a symlink to it). Code quality is enforced by
tooling rather than by convention. [ADR 0003](docs/adr/0003-quality-enforcement.md)
explains how, [`docs/architecture.md`](docs/architecture.md) describes the structure,
and [`docs/golden-principles.md`](docs/golden-principles.md) covers the judgement calls.
