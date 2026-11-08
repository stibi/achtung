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
| Services | `services/` | db, sources (index only), domain | Use cases such as ingest, acknowledge, list. Owns transactions. |
| Storage | `db/` | domain | Drizzle schema, migrations, repositories. Maps rows to domain types and back. |
| Sources | `sources/` | domain, zod | One folder per source. Turns a raw webhook body into `IncomingAlert[]`. No I/O. |
| Domain | `domain/` | nothing | Types and pure functions: alert model, severity, lifecycle rules. No libraries, no I/O. |
| Config | `config.ts` | zod | The only place that reads `process.env`. |

Enforced by `dependency-cruiser` (`server/.dependency-cruiser.cjs`):
- The domain is pure.
- `db/` imports only the domain. Services never import HTTP, and HTTP never imports `db/`.
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
- `index.ts`: exports one `SourceAdapter` (`src/sources/source-adapter.ts`).
- Tests in `test/sources/<id>.test.ts`, run against anonymized real payloads in
  `test/fixtures/<id>/`.

The Alertmanager adapter is the reference implementation, so copy its shape. Adding a
source must not require changes to the domain or to other adapters. If it seems to,
the domain model is missing a concept. Discuss it and record an ADR.

## Alert identity and lifecycle

- An alert is identified by `(source, channel, sourceKey)`. For Alertmanager,
  `sourceKey` is the `fingerprint`.
- One **occurrence** is `(identity, startsAt)`. If an alert resolves and later fires
  again, Alertmanager gives it a new `startsAt`, so it becomes a new occurrence.
- Ingest is idempotent. A repeat notification for an occurrence that is already firing
  updates it in place and does not count as new.
- What a notification means for an occurrence is decided by `eventFor` in
  `src/domain/occurrence.ts`:

  | Stored | Incoming | Event |
  |---|---|---|
  | none | firing | `fired` |
  | none | resolved | `resolved` (the firing was missed) |
  | firing | resolved | `resolved` |
  | resolved | firing | `reopened` (Alertmanager's `resolve_timeout` ended it too early) |
  | same status | same status | none: fields are updated, nothing is new |

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
- Tables (`src/db/schema.ts`): `channels`, `occurrences` (one row per occurrence, with
  the latest fields reported for it), and `events` (append-only history). Raw payloads
  are not stored. `events.id` is not a safe stream cursor: ids are assigned at insert,
  so a lower id can commit after a higher one. Solve that when SSE is built.
- Migrations are SQL files in `server/drizzle/`, generated from the schema by
  `pnpm run db:generate` and committed. `pnpm run check` fails when the schema has
  changes without a migration. The server applies pending migrations at startup, under
  a Postgres advisory lock so replicas can start together.

## Client API

- Routes under `/api/` (`src/http/api.ts`), all read-only for now:
  - `GET /api/channels`: channels by instance and name, with how many occurrences are
    firing and the latest event time. The client shows them as a tree: instances, then
    their channels. `Channel` and `Occurrence` both carry `instance`.
  - `GET /api/instances/{instance}/channels/{slug}/occurrences?status=&cursor=&limit=`:
    newest change first, ordered by `(lastEventAt, id)`. A repeat notification does not
    move an occurrence; a fire, resolve or reopen does. `nextCursor` is opaque; pass it
    back as `cursor`. The older `GET /api/channels/{slug}/occurrences` is deprecated; it
    resolves the name like the old ingest URL does.
  - `GET /api/occurrences?status=&cursor=&limit=`: the same list across every channel,
    in the same order and with the same paging; each occurrence's `channel` says where
    it belongs. This feeds the client's Live view.
  - `GET /api/occurrences/{id}`: the occurrence, its events (oldest first) and the
    alert's other occurrences (newest first, up to 20).
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
  `HOST`, `PORT`, `LOG_LEVEL`. The standard libpq variables (`PGPASSWORD`, …) fill in what
  `DATABASE_URL` leaves out, so a password never needs URL-encoding.
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
- `Achtung/`: the app target, SwiftUI. The sidebar (`InboxSidebar`) lists Live, then
  each instance with its channels underneath. Each row has a trailing badge with its
  unread occurrences and, next to the name in white on red, its unread critical ones
  (hidden at 0); an instance shows the sums of its channels, Live the sums of all. A row
  with nothing unread is greyed out, and a dot means something happened since the user
  last looked. Instances with anything unread come first, then the rest, each group by
  name; channels inside an instance follow the same rule (`Instance.sidebar` in
  AchtungDomain holds these rules). Live (`GET /api/occurrences`) is one stream of
  every channel's occurrences, each as a card with all its details and its instance and
  channel; clicking a card marks it read, and visiting Live counts as visiting every
  channel whose newest change it has loaded. A channel
  (`GET /api/instances/{instance}/channels/{slug}/occurrences`; the deprecated route by
  name alone is not used) is a list in a fixed-width column (summaries wrap), with a
  detail pane that loads the occurrence's events and the alert's other occurrences.
  Opening a channel selects its first unread occurrence, if any. If the open channel disappears, for example
  because the operator moved it to another instance, the view switches to Live. Both are newest change first and paged by `nextCursor`; `OccurrenceScope`
  (all channels or one) selects the route. `InboxModel` is the only code that talks to the server; the
  views only read it. `SampleData` exists for SwiftUI previews.
- No push yet: the app refreshes every 30 seconds and whenever it becomes active. A
  refresh reloads the channels and the all-channels feed, plus the selected channel's
  list, asking each for everything changed since a minute before its newest known
  `lastEventAt`. The unread counts are made from the feed: `GET /api/channels` has no
  unread information (read state is the client's), so every refresh also pages the feed
  back to the read baseline, at most 2000 occurrences; past that, counts cover only the
  newest ones. The server stamps `lastEventAt`
  before its transaction commits, so a change can appear after a later-stamped one; the
  overlap catches it, and merging by id makes it harmless.
- Read state (ADR 0002) is per server and stored in `UserDefaults`. It holds server
  times only, so the Mac's clock doesn't matter. Channel visits are keyed by
  `ChannelID`; visits stored before instances existed, keyed by name alone, are dropped
  on load (read marks and the last-visit marker are kept). An occurrence is read when the
  user has opened it at its current `lastEventAt`, or when its `lastEventAt` is at or
  before the baseline; a fire, resolve or reopen after that makes it unread again, and a
  repeat notification doesn't. The baseline is set once, on the first refresh after
  unread counts arrived (also for a migrated stored state), to the newest `lastEventAt`
  on the server, so an existing backlog doesn't all show as unread. "New since last visit" means a `lastEventAt`
  after the newest event the client had loaded when the app last went to the
  background.
- The server address is a setting (Settings window). The app allows plain HTTP (ATS
  exception in the generated Info.plist): servers are self-hosted and protected by the
  operator's network, not by TLS (ADR 0002).
- Package dependencies enforce the layering. The compiler rejects imports a package
  hasn't declared.
- The domain and API packages must build on Linux, so they can't import AppKit or
  SwiftUI. Enforced by a SwiftLint custom rule (`macos/.swiftlint.yml`) and by a CI job
  that runs `swift test` for both packages on Linux.
