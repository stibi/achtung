# Architecture

How the code is organized and why. Product context is in [`../README.md`](../README.md).
Most rules here are enforced by tooling. The tool that enforces each rule is named next
to it.

## Data flow

```
Alertmanager ──POST /ingest/alertmanager/{channel}──▶ http ──▶ sources/alertmanager.parse()
                                                        │            │ IncomingAlert[]
                                                        ▼            ▼
                                                     services (dedupe, lifecycle, events)
                                                        │
                                                        ▼
                                                       db (Postgres)
                                                        │
macOS client ◀──── REST API + Server-Sent Events ───── http
```

Planned parts not built yet: the client API and SSE. When you add one, follow the layer
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

- `POST /ingest/{source}/{channel}`, one route per source adapter. A channel is created
  on its first notification ([ADR 0005](adr/0005-ingest-channels-and-migrations.md)).
  Names must match `^[a-z0-9][a-z0-9-]{0,62}$`, anything else is a 404. An invalid
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

## Runtime

- Node.js runs the TypeScript sources directly using type stripping. There is no build
  step. Because of that, only erasable syntax is allowed (no `enum` and no
  `namespace`), enforced by `erasableSyntaxOnly`. `tsc` only type-checks.
- Relative imports use the `.ts` extension.
- Configuration comes from the environment (`src/config.ts`): `DATABASE_URL` (required),
  `HOST`, `PORT`, `LOG_LEVEL`.
- Logs are structured JSON from pino (through Fastify). `/healthz` reports liveness and
  `/readyz` reports readiness, which fails with a 503 while the database is unreachable.

## macOS client (`macos/`, planned)

- The Xcode project is generated from `project.yml` with XcodeGen and is not committed.
- Packages: `AchtungDomain` (models, no UI), `AchtungAPI` (generated from
  `api/openapi.yaml`), and `AchtungApp` (SwiftUI). Package dependencies enforce the
  layering. The compiler rejects imports a package hasn't declared.
- The domain and API packages must build on Linux, so they can't import AppKit or
  SwiftUI.
