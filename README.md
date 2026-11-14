# Achtung

**A self-hosted alert inbox for Prometheus Alertmanager, with a native macOS app.** It
replaces alerts in Microsoft Teams or Slack channels with a tool built for alerts: one
entry per alert with its history, unread state, search, macOS notifications, and
Alertmanager silences one click away. The server runs as a single container on
Kubernetes, next to your Alertmanagers.

![The macOS app in demo mode: Home with each Alertmanager's health, silencing two alerts from a tile, searching across channels by label, an alert's details and Copy for Agent, the Unread only switch and Mark All as Read, then a new critical alert arriving in Live with its macOS notification](docs/media/achtung-demo.gif)

A 43-second tour of the macOS app in demo mode, with made-up alerts (`make demo`).
[Full-quality video (MP4)](docs/media/achtung-demo.mp4).

> **Status:** early development, used daily by its author. Alertmanager is the only
> source so far. The server and the macOS app work end to end: ingest, Home, search,
> silences, notifications. Live updates over Server-Sent Events are being built (see
> [Roadmap](#roadmap)).

## Why: chat channels are bad at alerts

Sending Alertmanager to a Microsoft Teams (or Slack) channel is the default setup, and
it fails at the job:

- **You can't tell what's new.** Every repeat is another card. Firing and resolved look
  almost the same, and the cards are hard to scan.
- **Delivery breaks when it matters.** Teams throttles incoming webhooks, so alerts
  arrive late or not at all, often during the busiest incidents.
- **Setup is fragile.** Connectors and workflows are fiddly to configure and break
  quietly.
- **Wrong model.** A chat message is fire and forget. An alert has an identity, labels
  and a lifecycle (firing, resolved, firing again), and you need to act on it.

Achtung keeps Alertmanager as the brain (routing, grouping, inhibition) and becomes the
inbox: it tracks each alert's state, shows what changed since you last looked, and lets
you silence it where it came from.

## Features

- **One entry per alert, with its history.** Repeats update it instead of piling up.
  Every firing is kept, so you see how often an alert came back.
- **New since you last looked.** Unread badges per channel, an "Unread only" view and
  Mark All as Read (⇧⌘K).
- **Resends resurface.** An alert still firing after an hour comes back as *resent*,
  marked apart from new ones.
- **Home:** every Alertmanager at a glance: open alerts by severity, silenced, inhibited,
  its Watchdog, the Grafana IRM heartbeat, and alerts that never reached the inbox.
- **Live:** every channel in one stream, beside a 24-hour timeline.
- **Silences** for one alert, or many from a Home tile, created on the Alertmanager the
  alert came from. Change or end them later.
- **Search** across all channels by text, exact labels (`namespace=prod`), severity and
  instance.
- **macOS notifications** for critical alerts, with Mark as Read and Silence on the
  banner. They keep coming from the menu bar with the window closed, and what fired
  while the app was closed notifies on the next launch.
- **Readable alerts:** summary and description as prose, links as buttons, every label
  a hover away from copying. **Copy for Agent** (⇧⌘C) puts the whole alert on the
  clipboard as Markdown for an AI agent.
- **Zero setup per channel:** point an Alertmanager receiver at a new URL and the
  channel exists.
- **Self-hosted, small and open source:** one container, one Postgres, no accounts. MIT
  licensed.

## How it works

```
Alertmanager ──webhook──▶ server ──▶ PostgreSQL
     ▲                      │
     └── silences, alerts ──┤  REST API (OpenAPI)
Grafana IRM ◀── heartbeats ─┤
                            ▼
                      macOS app (polls every 30 s; SSE in progress)
```

- **Server:** TypeScript on Node.js, Fastify, PostgreSQL
  ([ADR 0001](docs/adr/0001-tech-stack.md)). One container image with no build step,
  runs with a read-only root filesystem and applies its migrations on startup.
- **Ingest:** each Alertmanager receiver posts to
  `POST /ingest/alertmanager/{instance}/{channel}`. The *instance* is the sending system
  (one cluster's Alertmanager), the *channel* a stream of alerts under it (an app or a
  team). Both are created by their first notification
  ([ADR 0005](docs/adr/0005-ingest-channels-and-migrations.md),
  [ADR 0006](docs/adr/0006-channel-instances.md)). Each source is an adapter that maps
  its payload to one internal model, so more sources can follow.
- **Client API:** described in [`api/openapi.yaml`](api/openapi.yaml), generated from
  the server's schemas. The macOS app's API client is generated from the same file.
- **macOS app:** Swift 6, SwiftUI, latest macOS. Read state lives on your Mac, so the
  server keeps no per-user state.

[`docs/architecture.md`](docs/architecture.md) has the layers and the data flow in
detail, and [`docs/adr/`](docs/adr/) has the reasons behind each decision.

### Concepts

| Concept | Meaning |
|---|---|
| **Instance** | A system that sends alerts, e.g. one Kubernetes cluster's Alertmanager. |
| **Channel** | A stream of alerts within an instance, one webhook URL each. |
| **Alert** | Identified by its source, channel and key (for Alertmanager the `fingerprint`, a hash of its labels). |
| **Occurrence** | One firing of an alert, from start to resolve. A new firing is a new occurrence. |
| **Event** | What happened to an occurrence: fired, resolved, reopened or resent. |
| **Read state** | What this Mac has seen. Stored locally, never on the server. |

## Alert identity and history

![An alert's detail in the macOS app: summary and description, runbook and dashboard links as buttons, labels one per row, and beside them the occurrence's events and the alert's earlier occurrences](docs/media/alert-detail.png)

Alertmanager repeats a firing alert every `repeat_interval` and retries failed
deliveries, so ingest is idempotent: a notification for an occurrence that already
fires updates it in place and counts as nothing new. An alert is recognized by
`(source, channel, fingerprint)`, and each firing (a new `startsAt`) becomes a new
occurrence of it. The detail lists the alert's other occurrences, newest first, so a
flapping alert shows as one. One transaction per notification, with rows locked in a
fixed order, keeps an Alertmanager HA pair delivering the same notification from
counting it twice. [ADR 0007](docs/adr/0007-alert-identity-and-history.md).

If Alertmanager drops an alert without sending the resolve (a silence, a restart), the
server notices: an occurrence still firing in the inbox but gone from its Alertmanager
for 5 minutes is resolved and marked *Gone from Alertmanager*
([ADR 0014](docs/adr/0014-resolve-vanished-occurrences.md)).

## Resends resurface alerts

![A channel in the macOS app with a resent alert: a circular arrow instead of the unread dot, and a "Resent" pill with the time in its header](docs/media/resent.png)

A chat channel shows every repeat; a plain inbox would show none, and a long-firing
alert would sink out of sight. The middle ground: once an hour without other events, a
repeat records a `resent` event. The alert becomes unread again, with a circular arrow
instead of the dot, and can notify again.
[ADR 0009](docs/adr/0009-resends-resurface-alerts.md).

## Unread, Live and the timeline

![Live in the macOS app: alert cards from every channel, newest change first, beside a 24-hour timeline with a marker where each alert fired and resolved, coloured by severity](docs/media/live.png)

The sidebar groups channels under their instance, with unread and unread-critical
badges. Channels and Live show only unread alerts by default, until you switch
"Unread only" off for that list. Mark All as Read (⇧⌘K) clears a list without moving any
baseline, so a later change stays unread. Live puts every channel in one stream next to a
timeline of the last 24 hours. When it is all caught up, the app's rat takes a coffee
break:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="macos/Icon/coffee-break/coffee-break-dark-small.gif">
  <img src="macos/Icon/coffee-break/coffee-break-light-small.gif" alt="Pixel-art animation shown when Live is all caught up: a rat at a table sipping coffee, an unused fire extinguisher in the corner">
</picture>

## Home: every Alertmanager's health

![Home in the macOS app: a tile per Alertmanager with its open alerts by severity, silenced and inhibited counts, Watchdog and IRM hearts and a delivery warning, then silences ending soon, the noisiest alerts and the longest firing ones](docs/media/home.png)

Home answers "is my alerting healthy?" rather than "what fired?". Each configured
Alertmanager is a tile, with numbers read from the Alertmanager's own API (at most every
30 seconds, cached on the server):

- open alerts by severity, and what is silenced or inhibited;
- a heart for its `Watchdog` alert;
- a second heart for **Grafana IRM**: whether IRM actually receives the heartbeat this
  Alertmanager sends it, from IRM's `OnCallHeartBeatMissing` alert groups
  ([ADR 0012](docs/adr/0012-irm-heartbeat.md));
- **delivery problems**: alerts Alertmanager should have sent but the inbox doesn't have,
  and alerts the inbox still shows as firing that Alertmanager has dropped.

Below the tiles: silences ending soon, the noisiest alerts of the last day and the
longest firing ones. Alerts that fire forever by design (`Watchdog`, `InfoInhibitor`,
`grafana-irm-heartbeat` by default) are left out of Home through a shared list of ignored
alert names, editable in Settings ([ADR 0010](docs/adr/0010-home-view.md),
[ADR 0011](docs/adr/0011-ignored-alert-names.md)).

## Silences through the server

![Silencing an alert in the macOS app: the silence button's menu with 1h, 4h, 1d and 1w, then the alert's header showing "Silenced until" and the menu to change or end it](docs/media/silence.gif)

Alertmanager stays the source of truth: the inbox stores no silences. Silencing an alert
creates a silence on the Alertmanager it came from, with an exact matcher for each of
its labels, for 1 hour to 1 week. Every alert shows whether it is silenced and until
when, including by silences made in Alertmanager itself. The alert's own silence can be
changed or ended from the app; broader ones stay Alertmanager's. A silence mutes the
alert for every receiver of that Alertmanager, not only in the inbox
([ADR 0008](docs/adr/0008-silences-through-the-server.md),
[ADR 0015](docs/adr/0015-change-and-end-silences.md)).

![An Alertmanager's detail opened from its Home tile: alerts grouped by severity with checkboxes, and "Silence 2 Selected…" asking for confirmation](docs/media/home-silence.gif)

From a Home tile you can silence several alerts at once, each with its own exact
silence, including alerts Alertmanager has but the inbox never received
([ADR 0016](docs/adr/0016-silence-alertmanager-alerts-in-bulk.md)).

## Search

![Searching in the macOS app: typing a query, a label filter turning into a token, and results from several channels with each row's channel](docs/media/search.gif)

⌘F searches every channel and instance on the server: free text in an alert's name,
summary or labels, exact label filters (`namespace=prod`), `severity:critical` and
`instance:<name>`. Filters become tokens as you type. Results stay live like any list,
and a label's context menu in an alert's details searches for it
([ADR 0017](docs/adr/0017-search-occurrences.md)).

## Notifications that survive restarts

![A macOS notification for a new critical alert, its Options menu with Mark as Read and Silence 1h, 4h, 1d and 1w, then the alert opening in the app](docs/media/notification.gif)

New, reopened and resent critical alerts (warning too, if you choose) post a macOS
notification with Mark as Read and Silence on it. More than three at once become one
summary. Closing the window leaves the app in the menu bar with a count of unread
critical alerts, and it keeps polling the server
([ADR 0013](docs/adr/0013-macos-notifications-and-background-polling.md)).

![The menu bar item: a bell with the unread critical count, the newest critical alerts, Mark Critical Alerts as Read and Pause Notifications](docs/media/menu-bar.png)

The notification state is saved per server, so what fired while the app was closed
(an update, a crash, a reboot) notifies on the next launch, once. After more than a day
away, the app starts fresh instead of flooding you. The alert already open on screen
gets no banner ([ADR 0018](docs/adr/0018-notifications-survive-restarts.md)).
Notifications need the Mac awake and the app running: they are not a pager, and paging
stays with Alertmanager's own receivers.

## Roadmap

- **Live change stream** (in progress). `GET /api/events`, a Server-Sent Events stream
  that says *what kind* of thing changed (alerts, silences, settings), so clients re-read
  at once instead of waiting up to 30 seconds for their next poll. The server side is
  built and waiting to be merged. The macOS app doesn't use it yet. Polling stays as a
  slower fallback.
- **Dead man's switch** (planned). A witness outside the cluster the inbox runs in, which
  alerts when expected heartbeats *stop*: silence otherwise looks like health. The
  inbox would send a deep heartbeat (each Watchdog seen, time of the last ingest) and show
  the switches on Home.
- **Investigate with an agent** (planned). One button in an alert's detail that hands
  the alert to a coding agent, which investigates read-only and posts its findings back
  to the alert. It builds on the change stream and on today's Copy for Agent.
- **Acknowledgement** (planned): mark an alert as being worked on, for everyone.
- **Users and collaboration** (future direction). Sign-in through OIDC, notes on an
  alert, comments on alerts and events in Live, perhaps very light messaging. Today
  there are no users or sign-in by design
  ([ADR 0002](docs/adr/0002-no-authentication.md)), so this needs a new decision first.
- **More sources** beyond Alertmanager, such as Grafana, Uptime Kuma or cron and backup
  jobs.

## Quick start

There is no published container image or app build yet: build both from source.

**Server.** Requirements: a PostgreSQL database and a place to run a container (in
practice Kubernetes, behind an ingress).

```bash
docker build -t achtung .        # the server image, from the root Dockerfile
docker run -p 8080:8080 \
  -e DATABASE_URL=postgres://achtung@db.example.com/achtung -e PGPASSWORD=… \
  -e ALERTMANAGERS='{"prod": {"url": "http://alertmanager.example.com:9093"}}' \
  achtung
```

| Variable | |
|---|---|
| `DATABASE_URL` | Required. Standard libpq variables such as `PGPASSWORD` fill in the rest. |
| `ALERTMANAGERS` | Optional JSON: instance name → `{ "url", "username", "password", "irmIntegrationId" }`. Enables silences and Home for that instance. Holds credentials, so set it from a secret. |
| `IRM_API_URL`, `IRM_API_TOKEN` | Optional, together: the Grafana IRM heartbeat on Home tiles. |
| `HOST`, `PORT`, `LOG_LEVEL` | Defaults `0.0.0.0`, `8080`. |

`/healthz` and `/readyz` are the liveness and readiness probes.

**Alertmanager.** Add a webhook receiver per channel. The URL names the instance and the
channel (lowercase letters, digits and dashes):

```yaml
receivers:
  - name: payments
    webhook_configs:
      - url: http://achtung.example.com/ingest/alertmanager/prod/payments
        send_resolved: true
```

You can add it next to an existing Teams or Slack receiver and compare.

**macOS app.** On a Mac with Xcode, `brew install xcodegen swiftlint periphery`, then
`macos/scripts/install.sh` builds a Release app into `~/Applications`. Set the server's
address in Settings. To try the app without a server, `make demo` runs it against a fake
server with made-up alerts.

### Security model

Today there is **no authentication and no users**
([ADR 0002](docs/adr/0002-no-authentication.md)). Anyone who can reach an instance sees
every alert, and anyone who can reach the ingest endpoints can post alerts. **Don't
expose it to the internet unprotected.** Restrict the ingress to your network or VPN, or
put an authenticating proxy (oauth2-proxy, basic auth) in front of it.

## Non-goals

- Replacing Alertmanager's routing, grouping, inhibition or silencing. Alertmanager is
  the brain, the inbox is the inbox.
- On-call scheduling, escalation and paging (PagerDuty and Grafana IRM territory).
- iOS, web or Windows clients for now. The API doesn't prevent them.
- Multi-tenant SaaS.

## Development

Tool versions are pinned in `.tool-versions`. Use pnpm. Tests need Docker: they run
against a real Postgres with Testcontainers.

```bash
pnpm install                        # dependencies and git hooks
pnpm --dir server run check         # typecheck, lint, architecture, migrations, tests
pnpm --dir server run fix           # auto-fix formatting and lint
DATABASE_URL=postgres://… pnpm --dir server run dev   # run the server locally on :8080
make help                           # the macOS app's shortcuts: run, demo, install, check, test, xcode
macos/scripts/check.sh              # the macOS app's format, lint, tests, build and dead code
```

The project is developed mostly by coding agents. Their rules are in
[`AGENTS.md`](AGENTS.md) (`CLAUDE.md` is a symlink to it). Code quality is enforced by
tooling rather than convention ([ADR 0003](docs/adr/0003-quality-enforcement.md),
[ADR 0004](docs/adr/0004-macos-client-tooling.md));
[`docs/architecture.md`](docs/architecture.md) describes the structure and
[`docs/golden-principles.md`](docs/golden-principles.md) the judgement calls.

## License

Open source under the [MIT License](LICENSE).
