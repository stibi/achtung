# Architecture

How the code is organized and why. Product context is in [`../README.md`](../README.md).
Most rules here are enforced by tooling. The tool that enforces each rule is named next
to it.

## Data flow

```
Alertmanager ──POST /ingest/alertmanager/{instance}/{channel}──▶ http ──▶ sources/alertmanager.parse()
                                                        │            │ IncomingAlert[]
                                                        ▼            ▼
                                                     services (dedupe, lifecycle, events)
                                                        │
                                                        ▼
                                                       db (Postgres)
                                                        │
macOS client ◀──── REST API + Server-Sent Events ───── http

services ──▶ clients ──GET silences, GET alerts (each ≤ 1 per 30 s per instance)──▶ Alertmanager API
                     ──POST silence (the silence button)──────────────────────────▶
                     ──GET alert_groups (≤ 1 per minute per integration)──────────▶ Grafana IRM API
```

Planned parts not built yet: SSE and acknowledgement. When you add one, follow the layer
rules below and update this file.

## Server layers (`server/src/`)

Dependencies point downward only. A layer may import the layers below it, never the
layers above it.

| Layer | Path | May import | Responsibility |
|---|---|---|---|
| Composition root | `main.ts` | everything | Read config, build dependencies, start the HTTP server, shut down on SIGTERM. Nothing imports it. |
| HTTP | `http/` | services, sources (index only), domain, config types | Fastify app, routes, request/response schemas. Thin: parse the request, call a service, map the result to a response. Never touches `db/`; `main.ts` passes services in. |
| Services | `services/` | db, clients, sources (index only), domain | Use cases such as ingest, silence, list. Owns transactions. |
| Clients | `clients/` | domain, zod | Calls to other systems' APIs, e.g. Alertmanager's silences and alerts, Grafana IRM's alert groups. Maps their answers to domain types. |
| Storage | `db/` | domain | Drizzle schema, migrations, repositories. Maps rows to domain types and back. |
| Sources | `sources/` | domain, zod | One folder per source. Turns a raw webhook body into `IncomingAlert[]`. No I/O. |
| Domain | `domain/` | nothing | Types and pure functions: alert model, severity, lifecycle rules. No libraries, no I/O. |
| Config | `config.ts` | zod | The only place that reads `process.env`. |

Enforced by `dependency-cruiser` (`server/.dependency-cruiser.cjs`):
- The domain is pure.
- `db/` imports only the domain. Services never import HTTP, and HTTP never imports `db/`
  or `clients/`.
- `clients/` may use only the domain and zod.
- Sources may use only the domain and zod.
- Adapters never import each other.
- Code outside an adapter imports it only through its `index.ts`.
- `config.ts` is a leaf, and nothing imports `main.ts`.
- No cycles and no orphan modules.
- `src/` does not import dev dependencies.

## Source adapters

A source is a folder `src/sources/<id>/` containing:

- `payload.ts`: Zod schema of the webhook body, with a link to the upstream docs.
- `map.ts`: pure mapping from the payload to `IncomingAlert`.
- `index.ts`: exports one `SourceAdapter` (`src/sources/source-adapter.ts`). Besides the
  alerts, its result names the sender's configuration that sent the notification
  (`receiver`, Alertmanager's receiver), or null when the source has no such name.
- Tests in `test/sources/<id>.test.ts`, run against anonymized real payloads in
  `test/fixtures/<id>/`.

The Alertmanager adapter is the reference implementation, so copy its shape. Adding a
source must not require changes to the domain or to other adapters. If it seems to,
the domain model is missing a concept. Discuss it and record an ADR.

## Alert identity and lifecycle

The identity below is a contract that features build on
([ADR 0007](adr/0007-alert-identity-and-history.md)). Changing it needs a new ADR.

- An alert is identified by `(source, channel, sourceKey)`, and the channel includes its
  instance. For Alertmanager, `sourceKey` is the `fingerprint`, a hash of the full label
  set. Every adapter must provide a `sourceKey` that stays the same across firings.
- One **occurrence** is `(identity, startsAt)`. If an alert resolves and later fires
  again, Alertmanager gives it a new `startsAt`, so it becomes a new occurrence.
- Ingest is idempotent. A repeat notification for an occurrence that is already firing
  updates it in place and does not count as new. If the occurrence's last event was an
  hour ago or more, the repeat records a `resent` event, which resurfaces the alert
  ([ADR 0009](adr/0009-resends-resurface-alerts.md)).
- What a notification means for an occurrence is decided by `eventFor` in
  `src/domain/occurrence.ts`:

  | Stored | Incoming | Event |
  |---|---|---|
  | none | firing | `fired` |
  | none | resolved | `resolved` (the firing was missed) |
  | firing | resolved | `resolved` |
  | resolved | firing | `reopened` (Alertmanager's `resolve_timeout` ended it too early) |
  | firing | firing, last event ≥ 1h ago | `resent` (a reminder; not counted as new) |
  | same status | same status | none: fields are updated, nothing is new |

- One event has no notification behind it: an occurrence still firing in Achtung that
  its Alertmanager no longer has, for 5 minutes of reads, is resolved by
  `services/reconcile.ts` with a `resolved` event whose `cause` is `vanished`
  ([ADR 0014](adr/0014-resolve-vanished-occurrences.md)). A later firing notification
  reopens it like any resolved occurrence.

## Ingest and storage

- `POST /ingest/{source}/{instance}/{channel}`, one route per source adapter (also in
  `api/openapi.yaml`, under the `ingest` tag). The instance is the sending system, e.g.
  one cluster's Alertmanager. A channel belongs to an instance, and both are created on
  their first notification ([ADR 0005](adr/0005-ingest-channels-and-migrations.md),
  [ADR 0006](adr/0006-channel-instances.md)). Names must match
  `^[a-z0-9][a-z0-9-]{0,62}$`, anything else is a 404.
- The older `POST /ingest/{source}/{channel}` is deprecated. It delivers to the one
  named instance's channel of that name, else to the `default` instance's. Switch a
  sender to the new URL before another instance reuses its channel names (ADR 0006). An invalid
  payload is a 400 and is logged with its body. Success is a 200 with
  `{ alerts, new, resolved }`.
- One transaction per notification. Occurrences are inserted with `ON CONFLICT DO
  NOTHING`, and existing ones are locked (`FOR UPDATE`) before they change. Alerts are
  processed in a fixed order, so concurrent deliveries of the same notification (an
  Alertmanager HA pair) wait for each other instead of deadlocking or double-counting.
- Tables (`src/db/schema.ts`): `channels` (with the `receiver` that last delivered to
  it, written only when it changes, so ingest doesn't lock the row), `occurrences` (one
  row per occurrence, with the latest fields reported for it), `events` (append-only
  history), and `ignored_alert_names` (a setting, ADR 0011). Raw payloads
  are not stored. `events.id` is not a safe stream cursor: ids are assigned at insert,
  so a lower id can commit after a higher one. Solve that when SSE is built.
- Migrations are SQL files in `server/drizzle/`, generated from the schema by
  `pnpm run db:generate` and committed. `pnpm run check` fails when the schema has
  changes without a migration. The server applies pending migrations at startup, under
  a Postgres advisory lock so replicas can start together.

## Client API

- Routes under `/api/` (`src/http/api.ts`), read-only except the silence button and the
  ignored alert names:
  - `GET /api/channels`: channels by instance and name, with how many occurrences are
    firing and the latest event time. The client shows them as a tree: instances, then
    their channels. `Channel` and `Occurrence` both carry `instance`.
  - `GET /api/instances/{instance}/channels/{slug}/occurrences?status=&cursor=&limit=`:
    newest change first, ordered by `(lastEventAt, id)`. A repeat notification does not
    move an occurrence; a fire, resolve, reopen or resend does. `lastEventKind` says
    which. `nextCursor` is opaque; pass it
    back as `cursor`. The older `GET /api/channels/{slug}/occurrences` is deprecated; it
    resolves the name like the old ingest URL does.
  - `GET /api/occurrences?status=&cursor=&limit=`: the same list across every channel,
    in the same order and with the same paging; each occurrence's `channel` says where
    it belongs. This feeds the client's Live view.
  - `GET /api/occurrences/{id}`: the occurrence, its events (oldest first) and the
    alert's other occurrences (newest first, up to 20).
  - `POST /api/occurrences/{id}/silence` with `{ "durationSeconds": 60..2592000 }`:
    silences exactly this alert (an equality matcher per label) on its instance's
    Alertmanager, from now, and returns the occurrence
    ([ADR 0008](adr/0008-silences-through-the-server.md)). 409 when the instance has no
    Alertmanager configured, 502 when Alertmanager is unreachable or refuses it.
  - `GET /api/home` ([ADR 0010](adr/0010-home-view.md)): one entry per configured
    Alertmanager, by instance name, plus the silences active on all of them (soonest to
    end first, from the silences cache below), the 10 noisiest alerts (most `fired`,
    `reopened` and `resent` events in the last 24 hours, at least 2, each as its newest
    occurrence) and the 10 longest firing occurrences. An entry's counts come from the
    Alertmanager itself (`GET /api/v2/alerts`), read at most every 30 seconds per
    instance by `services/home.ts` through the same cached reader as the silences
    (`services/alertmanager-reads.ts`: one read at a time, the last good one kept when a
    read fails, with `reachable: false` and the error, without the response body). Its
    `delivery` compares that read with what fires in Achtung, firing by firing
    (fingerprint and `startsAt`): alerts notifying for over 10 minutes, routed to a
    receiver a channel of that instance recorded, but not firing in Achtung and not
    changed there since the read (`missingInAchtung`), and occurrences firing in Achtung,
    last notified over 10 minutes before the read, that Alertmanager no longer has
    (`staleInAchtung`). Home only reports; `services/reconcile.ts`, run every minute by
    `main.ts`, resolves what stays stale for 5 minutes ([ADR 0014](adr/0014-resolve-vanished-occurrences.md)),
    with a `resolved` event whose `cause` is `vanished`. The counting and the comparison are pure functions in
    `domain/overview.ts`. The counts and both delivery lists leave out the ignored alert
    names (below); `watchdog` doesn't, it still says whether `Watchdog` is there.
    An entry's `irm` ([ADR 0012](adr/0012-irm-heartbeat.md)) says whether Grafana IRM
    receives the instance's heartbeat: `receiving`, `missing` (since IRM opened its
    `OnCallHeartBeatMissing` alert group) or `unknown` (never read), with the last missed
    heartbeat, `checkedAt` and `error`. `services/irm-heartbeats.ts` reads the latest
    groups of the instance's `irmIntegrationId` through `clients/irm.ts`, at most once a
    minute per integration with the same `cachedRead` (one read at a time, the last good
    one kept on failure), in parallel with the rest of Home; `domain/irm-heartbeat.ts`
    maps them to the status. `irm` is null when IRM isn't configured or the instance has
    no integration.
  - `GET /api/alertmanagers/{instance}/alerts` (ADR 0010): the alerts behind an
    instance's Home tile, from the same cached read as its counts, so they always agree:
    `active` alerts (notifying or unprocessed) are its `open`, `silenced` and `inhibited`
    its other two counts; the ignored alert names are left out. By severity, then the
    newest start first. Each has its `occurrenceId`, the occurrence on that instance with
    the same fingerprint and `startsAt` (a re-fire doesn't match), or null, and a silenced
    one its `silencedUntil`, from the silences cache by the ids Alertmanager names. It
    reports `reachable`, `error` and `checkedAt` like a Home entry; one never read has no
    alerts. 404 for an instance without an Alertmanager. The standing, matching and order
    are `alertListOf` in `domain/overview.ts`, which shares its classification with
    `countAlerts`.
  - `GET` and `PUT /api/settings/ignored-alerts` ([ADR 0011](adr/0011-ignored-alert-names.md)):
    `{ names }`, the alert names the Home views above leave out, matched exactly and
    case-sensitively against `alertname`. One list shared by every client, stored in
    `ignored_alert_names` and seeded by its migration with `Watchdog`, `InfoInhibitor` and
    `grafana-irm-heartbeat`. `PUT` replaces the whole list in one transaction (the table
    locked, so two at once don't merge) and returns it; names are trimmed and stored once,
    and an empty name, one over 200 characters or over 200 names is a 400. The service
    reads the list for every Home request, not with the cached Alertmanager read, so a
    change applies to the next request; the domain functions take it as a parameter. It
    only concerns the Alertmanager-derived Home views: the inbox (channels, Live, the feed
    and the badges) shows these alerts as usual.
- Every occurrence carries `silencedUntil`: the end of the latest active silence on its
  instance's Alertmanager whose matchers match its labels, else null. Alertmanager is the
  source of truth; Achtung stores no silences. `services/silences.ts` reads each
  instance's silences at most every 30 seconds, keeps the last ones when Alertmanager
  can't be read (and logs a warning), and `domain/silence.ts` evaluates the matchers.
  The home view's alerts are read the same way, and a failed read is logged the same way.
- Errors are `{ "error": "…" }`: 400 for invalid input (including a cursor the server
  never issued), 404 for an unknown channel or occurrence.
- "New since last visit" is computed by the client from `lastEventAt` and its own read
  state (ADR 0002). The server keeps no per-client state.
- Known limitation: `lastEventAt` is stamped before the ingest transaction commits, so
  two concurrent changes can commit in the opposite order to their timestamps. A client
  marker set between the two commits misses the earlier-stamped change. The client
  overlaps refreshes by a minute; "new since last visit" can still miss it. Accepted for
  now (rare at alert volume). The fix is to stamp under a lock taken at the start of
  each ingest that changes something, or to add a change counter that is incremented
  under that lock. A plain sequence has the same race.
- The Zod schemas in `src/http/api-schemas.ts` validate every response and generate
  `api/openapi.yaml` (`src/http/openapi.ts` tidies it for the Swift generator). The file
  is committed; `check` fails when it is out of date, and `pnpm run api:generate`
  rewrites it. Its diff is the API change to review.

## Runtime

- Node.js runs the TypeScript sources directly using type stripping. There is no build
  step. Because of that, only erasable syntax is allowed (no `enum` and no
  `namespace`), enforced by `erasableSyntaxOnly`. `tsc` only type-checks.
- Relative imports use the `.ts` extension.
- Deployed as one container image (`Dockerfile`). It applies migrations on startup and
  writes nothing to disk, so it runs with a read-only root filesystem.
- Configuration comes from the environment (`src/config.ts`): `DATABASE_URL` (required),
  `HOST`, `PORT`, `LOG_LEVEL`, `ALERTMANAGERS`, `IRM_API_URL`, `IRM_API_TOKEN`. The
  standard libpq variables (`PGPASSWORD`, …) fill in what `DATABASE_URL` leaves out, so a
  password never needs URL-encoding.
- `ALERTMANAGERS` is a JSON object of instance name → `{ "url": "…", "username": "…",
  "password": "…" }` (the credentials are optional, basic auth). It holds credentials,
  so set it from a secret. An instance without an entry can't be silenced and has no
  entry in the home view. An entry may also name `irmIntegrationId`, its cluster's
  Grafana IRM integration, whose heartbeat its Home tile shows (ADR 0012).
- `IRM_API_URL` (e.g. `https://oncall-prod-eu-west-0.grafana.net/oncall`, no credentials
  in it) and `IRM_API_TOKEN` (sent raw as `Authorization`) go together or not at all.
  The token is a secret. Without them, no tile has an IRM heartbeat.
- Logs are structured JSON from pino (through Fastify). `/healthz` reports liveness and
  `/readyz` reports readiness, which fails with a 503 while the database is unreachable.

## macOS client (`macos/`)

- The Xcode project is generated from `project.yml` with XcodeGen and is not committed.
- `Packages/AchtungDomain`: the model, mirroring `server/src/domain/` (`Channel`,
  `Occurrence`, `IncomingAlert`, events), plus client-only rules: `OccurrenceList`
  (pages and refreshes merged in the server's `(lastEventAt, id)` order), `ReadState`,
  and `Instance` (channels grouped by the sending system, in the server's order).
  A channel is identified by `ChannelID`, its instance and name (ADR 0006), because two
  instances can have a channel of the same name. No UI and no I/O.
- `Packages/AchtungAPI`: the server client. swift-openapi-generator's build plugin
  generates it from `Sources/AchtungAPI/openapi.yaml`, a symlink to `api/openapi.yaml`,
  so nothing generated is committed and the spec has one copy. The generated code is
  `internal`; `Mapping.swift` turns it into AchtungDomain types, and failures into
  `ServerError`. The app never sees a generated type. Requests bypass the HTTP cache.
- `Achtung/`: the app target, SwiftUI. The sidebar (`InboxSidebar`) lists Home, Live,
  then each instance with its channels underneath; the app opens on Home. Each row has a trailing badge with its
  unread occurrences and, next to the name in white on red, its unread critical ones
  (hidden at 0); an instance shows the sums of its channels, Live the sums of all. A row
  with nothing unread is greyed out, and a dot means something happened since the user
  last looked. Instances with anything unread come first, then the rest, each group by
  name; channels inside an instance follow the same rule (`Instance.sidebar` in
  AchtungDomain holds these rules). Live (`GET /api/occurrences`) is one stream of
  every channel's occurrences, each as a card with all its details and its instance and
  channel; clicking a card marks it read, and visiting Live counts as visiting every
  channel whose newest change it has loaded. Beside the stream, a card shows the last 24
  hours as a vertical timeline, now at the top under a "now" line that moves with the
  clock (`LiveTimeline`; positions, bars and clustering are `Timeline` in AchtungDomain):
  a marker where each alert fired (filled) and resolved (hollow), in its severity's
  colour, unread ones ringed and read ones dimmed, and per severity one bar for when
  anything of it was firing, open to now while something still fires. Markers closer than
  18 points become one, drawn at its newest marker, with the number of alerts in it. Markers are buttons with
  an accessibility label; hovering shows the details, and clicking scrolls the stream to
  the card (a cluster's newest) and highlights it. Below 730 points of width the timeline
  goes away before the cards would get narrower. A channel
  (`GET /api/instances/{instance}/channels/{slug}/occurrences`; the deprecated route by
  name alone is not used) is a list in a fixed-width column (summaries wrap), with a
  detail pane: what the source reported in the main column, and the occurrence's
  channel, identity (source and key), delivery facts, events and the alert's other
  occurrences in a 280-point column on the right that scrolls on its own
  (`AlertMetadataPanel`). When the pane is narrower than 680 points, that column goes
  below the main one.
  Opening a channel selects its first unread occurrence, if any. If the open channel
  disappears, for example because the operator moved it to another instance, the view
  switches to Live. Both are newest change first and paged by `nextCursor`;
  `OccurrenceScope` (all channels or one) selects the route. `InboxModel`, the
  `HomeModel` it makes on the same server, and `IgnoredAlertsModel` (one in `HomeModel`,
  one in Settings) are the only code that talks to the server; the views only read them.
  `SampleData` exists for SwiftUI previews.
- An alert's details (`AlertDetails`, in the detail pane and on Live cards) read top
  down: the header, the summary and the `description` annotation as prose (inline
  Markdown, bare URLs made links), the links as buttons (the source's own and any
  annotation whose value is a URL, titled from its name), then every annotation (summary
  and description first) and every label, one per row on a card: the name in a column on
  the left, the value wrapping on the right, URLs clickable. Labels that say what and
  where come first (alertname, severity in its colour, cluster, namespace, job, pod,
  instance, service, container, deployment), then the rest by name. Hovering a row shows
  a button that copies `name=value`; its context menu also copies the value, or a label
  as a PromQL matcher. The order and the link titles are in AchtungDomain
  (`IncomingAlert.orderedAnnotations`, `orderedLabels`, `linkAnnotations`).
- An event's `cause` (ADR 0014) is mapped as `OccurrenceEvent.Cause`, and an unknown one
  is rejected like any value the spec doesn't list. The history shows a resolve Achtung
  recorded itself, because the alert was gone from its Alertmanager, as "Resolved …" over
  "Gone from Alertmanager", with a question-mark check and a help text saying
  Alertmanager never sent the resolve; Copy for Agent's history says so too.
- "Copy for Agent" (the details' button, ⇧⌘C in the detail pane, a list row's context
  menu) puts the alert on the pasteboard as Markdown for an agent to investigate
  (`AgentReport` in AchtungDomain): the title; its state, severity, instance and channel;
  its times in ISO 8601 UTC; the summary and description; the links; every other
  annotation; the labels sorted as `key=value` lines in a code block; its fingerprint
  and occurrence id; and its history when the detail pane has loaded it. Only what the
  alert carries. The button says "Copied" for a moment.
- Every alert, in the detail pane and on Live cards, has a silence button
  (`SilenceButton`, `POST /api/occurrences/{id}/silence`, ADR 0008): a split button whose
  main part silences for the remembered duration and whose menu offers 1h, 4h, 1d and 1w;
  the one picked silences and becomes the default (`SilenceDuration`, kept in
  `UserDefaults`). The server returns the occurrence with `silencedUntil`, which replaces
  it in every list. A silenced alert shows "Silenced until …" in its header, a muted bell
  in list rows, and a "Silenced" state instead of the button, until the silence ends;
  expiring a silence is done in Alertmanager. Its help text says that a silence mutes the
  alert for every receiver of that Alertmanager, not only in Achtung. A failure (409, 502)
  shows the server's reason next to the button. `silencedUntil` can change without
  `lastEventAt` moving (a silence made or expired in Alertmanager), so a refresh merges
  every fetched page whole, not only what changed: the newest page of Live and of the open
  channel picks up such changes within about a minute (the server reads Alertmanager at
  most every 30 seconds). Older loaded occurrences show them when they next change, or
  after a relaunch.
- No push yet: the app refreshes every 30 seconds, with or without a window (`AppModel`,
  ADR 0013), when a list opens, and whenever it becomes active. A refresh reloads the
  channels and the all-channels feed, plus the selected channel's list, asking each for
  everything changed since a minute before its newest known `lastEventAt`. The unread
  counts are made from the feed: `GET /api/channels` has no unread information (read state
  is the client's), so every refresh also pages the feed back to the read baseline, and to
  24 hours ago for the Live timeline, whichever is further, at most 2000 occurrences; past
  that, counts and timeline cover only the newest ones. It also loads every firing
  occurrence (`GET /api/occurrences?status=firing`), so the timeline shows an alert that
  started before the 24 hours and still fires. The server stamps `lastEventAt` before its
  transaction commits, so a change can appear after a later-stamped one; the overlap
  catches it, and merging by id makes it harmless.
- Read state (ADR 0002) is per server and stored in `UserDefaults`. It holds server
  times only, so the Mac's clock doesn't matter. Channel visits are keyed by
  `ChannelID`; visits stored before instances existed, keyed by name alone, are dropped
  on load (read marks and the last-visit marker are kept). An occurrence is read when the
  user has opened it at its current `lastEventAt`, or when its `lastEventAt` is at or
  before the baseline; a fire, resolve, reopen or resend after that makes it unread
  again. A resend (`lastEventKind` `resent`) is a repeat notification for an alert that
  still fires, recorded by the server at most once an hour; other repeats don't make it
  unread. A resent occurrence counts as unread in every badge, but shows a circular arrow
  instead of the unread dot (`UnreadMark`), a "Resent 14:05" pill in its header
  (`ResentPill`), "Resent" in its history, and a small circular arrow on the Live
  timeline at its last resend. The baseline is first set on the first refresh after
  unread counts arrived (also for a migrated stored state), to the newest `lastEventAt`
  on the server, so an existing backlog doesn't all show as unread. After each refresh
  whose feed reaches back to it (not stopped by the cap or by Live's own paging), it
  moves forward to just before the oldest unread occurrence, never past the newest loaded
  change minus the 60-second refresh overlap (so a late commit still counts as unread),
  and never back (`ReadState.advanceBaseline`). A change committed more than 60 seconds
  late, which the refresh would miss anyway, then counts as read. Read marks at or below
  the baseline are dropped, which can't change what is read: a mark only makes read what
  last changed at or below it, and the baseline covers all of that. So the backlog each
  launch pages through stays small and the stored read state doesn't grow without
  bound. "New since last visit" means a `lastEventAt`
  after the newest event the client had loaded when the app last went to the
  background.
- A channel's list and Live hide read occurrences by default, showing only new alerts and
  resends. An "Unread only" switch (`ListHeader`) sits in the toolbar in place of the
  window title, on the line of the list's name, and turns this off and on for each
  channel and for Live separately. The exceptions are stored in the read state
  (`ReadState.hidesRead`, a channel keyed by `ChannelID`). While hiding, a channel's list
  also takes the channel's unread occurrences from the all-channels feed, which holds
  every unread one, so it matches the sidebar count and needs no older pages: the "load
  older" row is hidden, in Live too. Where the feed and the channel's list hold different
  copies of an occurrence, the later `lastEventAt` wins. Opening an occurrence marks it
  read, so the one the user has open stays listed until they move on, also when hiding is
  turned off (`ReadState.shown`): a channel's selected occurrence, and in Live the card
  last clicked or shown from the timeline. Only opening a channel selects its first
  unread occurrence, never each later one. A resend lists it again. With nothing unread
  the list says "All caught up", with a button that shows read alerts again; Live's
  timeline stays beside it and always shows every alert. Badges are unchanged.
- Beside the switch, "Mark All as Read" (⇧⌘K) marks everything unread in the list read:
  what the list shows with unread only on, from the list and the all-channels feed
  (`ReadState.markAllRead`). That's the badge's set, plus the rare occurrence only the
  list has, or has newer: a change between a refresh's feed and list loads, or one past
  the feed's cap. Each occurrence is marked at the `lastEventAt` the client
  has loaded, never by moving a baseline to now, so whatever arrived after the last
  refresh, and any later resend, stays unread. It also lets go of the open alert (a
  channel's selection, Live's last clicked card), so with unread only on the list
  empties into "All caught up". There's no confirmation: read state is local, and a
  resend brings an alert back. It's disabled when nothing in the list is unread.
- Home (`GET /api/home`, `HomeView`, its state in `HomeModel`) shows each configured
  Alertmanager as a tile in an adaptive grid (`AlertmanagerTile`), with numbers from the
  Alertmanager itself, read by the server at most every 30 seconds (ADR 0010): its
  notifying alerts as a big total coloured by the worst severity present, or a green "All
  quiet"; a stacked severity bar and breakdown; what's silenced or inhibited; a heart for
  its Watchdog, and a second one labelled "IRM" for whether Grafana IRM receives its
  heartbeat (`AlertmanagerOverview.irm`, none without an IRM integration): green while it
  does, red while it doesn't, with "IRM missing the heartbeat since …" spelled out on the
  tile, grey when IRM was never read, dimmed when the latest read of IRM failed and the
  status is older. `IrmHeartbeat` in AchtungDomain has the tone, the texts and their
  durations; its status is either known, with when IRM was read, or unknown, and the
  mapping rejects a missing heartbeat without `since`, a last miss with one end, a known
  status never read and an unknown one that was. The tile also has a status dot for
  whether the server can read it (an unreachable one keeps its last numbers, dimmed; one
  never read says so) and, when delivery between it and Achtung broke, a capsule with the
  alerts missing in Achtung and those stale in it, in a popover. The domain's
  `AlertmanagerOverview.Status` is either reachable with its read, or unreachable with the
  error and its last read, if any; the mapping rejects anything else (a read there only in
  part, reachable but never read, unreachable without an error). Below the tiles: silences
  ending soon, the noisiest alerts of 24 hours and the longest firing, each a
  `FittedSection`: it shows as many rows as fit the height left under the tiles, measured
  from its own title and rows (`ListFit` in AchtungDomain does the arithmetic; stacked
  sections share the height, a short one passing on what it doesn't need), then "Show N
  more", which expands it and lets the page scroll. Never fewer than three rows, so a
  small window scrolls. It recomputes as the window resizes, collapses again once
  everything fits or when the user reloads Home (⌘R; the refresh every 30 seconds leaves
  an open list alone), and starts collapsed whenever Home appears. A future list on Home
  uses the same view. Rows with an occurrence open it in its channel, selected even when
  neither the channel's loaded pages nor the feed hold it
  (`InboxModel.shownOccurrences(revealing:)`), and let go when the user opens anything
  else. Home loads on its own, without waiting for the inbox's first refresh. It reloads
  every 30 seconds while the app is on screen, at once when it comes back, and on ⌘R.
- Clicking an Alertmanager's tile opens its detail in place of the tiles
  (`AlertmanagerDetailView`, `GET /api/alertmanagers/{instance}/alerts`, from the same
  read as its counts): the active alerts grouped by severity, most severe first, each with
  its summary, how long it has fired and a few key labels (`AlertmanagerAlert.keyLabels`,
  the rest in the help), then the silenced and inhibited ones, folded away; "All quiet"
  when nothing is active. A row with an occurrence in Achtung opens it in its channel; one
  without says "Not in Achtung". An instance the server no longer has says so. The mapping
  rejects impossible lists (reachable but never read, unreachable without an error, never
  read but listing alerts, a silence end on an alert that isn't silenced). Back or Esc
  returns to Home; the detail reloads every 30 seconds while on screen, at once when it
  comes back, and on ⌘R. A row's context menu, "Ignore Alerts Named “…”", adds its
  alertname to the ignored alert names.
- Ignored alert names (`GET`/`PUT /api/settings/ignored-alerts`): alert names Home leaves
  out of each Alertmanager's counts, its detail and its delivery check, matched exactly
  on alertname. One list on the server, shared by every user (ADR 0002); channels and
  Live show those alerts as usual, and Watchdog's heart doesn't depend on it. Settings has
  an Ignored Alerts tab (`IgnoredAlertsSettings`) that edits it: add with the field
  (Return or Add), remove the selection with − or Delete. Each change saves the whole list
  at once (`IgnoredAlertsModel`), and shows the server's 400 below the field. A change
  reads the list first and waits for the change before it, so neither a name removed
  elsewhere nor one added a moment ago is lost; the server's answer, trimmed,
  deduplicated and sorted, is the list from then on. A saved change posts
  `ignoredAlertNamesChanged` with the server's URL, so Home and an open detail reload at
  once, and Settings shows a change made from a detail.
- Live's "All caught up" has a small pixel scene above it (`CoffeeBreak`): the icon's
  krysa at a table, sipping coffee every few seconds, an unused fire extinguisher in the
  corner. `CoffeeBreakScene` places the pixels for a moment in the loop, and the view
  draws them on a `Canvas`, one path per colour. It only moves while its window is key,
  through a `TimelineSchedule` that wakes 8 times a second while the mug moves, not at
  all while the krysa holds it at its mouth, 4 times a second otherwise, and once a
  second when the system asks for low frequency. With Reduce Motion, or in the
  background, it's a plain still `Canvas`, because even a paused
  `TimelineView(.animation)` keeps the window redrawing. A setting ("Animate even when
  Reduce Motion is on", `MotionSetting`, off by default) lets it move despite the
  system's Reduce Motion, for people who want it in Achtung only. Its colours are in
  `CoffeeBreakPalette`, Foundation only, which `macos/scripts/render-coffee-break.sh`
  shares to export the scene as GIFs (`macos/Icon/coffee-break/`), so they match the app.
- Notifications (ADR 0013): `AppModel` owns the server connection (`InboxModel`) and its
  30-second refresh for the app's lifetime; closing the last window leaves Achtung in the
  menu bar (`MenuBarMenu`: a bell with the unread, unsilenced critical count, the newest
  five, mark them read, pause notifications, Settings, Quit). After each refresh it asks
  `AlertNotificationState` in AchtungDomain which occurrences to announce: new, reopened
  or resent firings after the connection's baseline (the first refresh's newest event),
  of the severities picked in Settings' Notifications tab, not silenced, read or ignored
  (ADR 0011), each event once (an in-memory ledger).
  `AlertNotifier` posts them, one each or one summary for more than three
  (`AlertNotificationPlan`), with Mark as Read and Silence 1h … 1w under Options (Mark
  All as Read on a summary). Its actions and clicks come back to `AppModel`, which uses
  `InboxModel`'s own read and silence paths and opens the window on the alert through
  `InboxModel.openRequest`. Reading an alert removes its delivered notification.
- The server address is a setting (Settings window, General tab). The app allows plain
  HTTP (ATS exception in the generated Info.plist): servers are self-hosted and protected
  by the operator's network, not by TLS (ADR 0002).
- Package dependencies enforce the layering. The compiler rejects imports a package
  hasn't declared.
- The domain and API packages must build on Linux, so they can't import AppKit or
  SwiftUI. Enforced by a SwiftLint custom rule (`macos/.swiftlint.yml`) and by a CI job
  that runs `swift test` for both packages on Linux.
