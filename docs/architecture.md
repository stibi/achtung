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

Planned parts not built yet: `services/`, `db/`, the ingest route, the client API and
SSE. When you add one, follow the layer rules below and update this file.

## Server layers (`server/src/`)

Dependencies point downward only. A layer may import the layers below it, never the
layers above it.

| Layer | Path | May import | Responsibility |
|---|---|---|---|
| Composition root | `main.ts` | everything | Read config, build dependencies, start the HTTP server, shut down on SIGTERM. Nothing imports it. |
| HTTP | `http/` | services, sources (index only), domain, config types | Fastify app, routes, request/response schemas. Thin: parse the request, call a service, map the result to a response. |
| Services | `services/` *(planned)* | db, sources (index only), domain | Use cases such as ingest, acknowledge, list. Owns transactions. |
| Storage | `db/` *(planned)* | domain | Drizzle schema, migrations, repositories. Maps rows to domain types and back. |
| Sources | `sources/` | domain, zod | One folder per source. Turns a raw webhook body into `IncomingAlert[]`. No I/O. |
| Domain | `domain/` | nothing | Types and pure functions: alert model, severity, lifecycle rules. No libraries, no I/O. |
| Config | `config.ts` | zod | The only place that reads `process.env`. |

Enforced by `dependency-cruiser` (`server/.dependency-cruiser.cjs`):
- The domain is pure.
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

## Runtime

- Node.js runs the TypeScript sources directly using type stripping. There is no build
  step. Because of that, only erasable syntax is allowed (no `enum` and no
  `namespace`), enforced by `erasableSyntaxOnly`. `tsc` only type-checks.
- Relative imports use the `.ts` extension.
- Logs are structured JSON from pino (through Fastify). `/healthz` reports liveness and
  `/readyz` reports readiness. Until there is a database, readiness is the same as
  liveness.

## macOS client (`macos/`, planned)

- The Xcode project is generated from `project.yml` with XcodeGen and is not committed.
- Packages: `AchtungDomain` (models, no UI), `AchtungAPI` (generated from
  `api/openapi.yaml`), and `AchtungApp` (SwiftUI). Package dependencies enforce the
  layering. The compiler rejects imports a package hasn't declared.
- The domain and API packages must build on Linux, so they can't import AppKit or
  SwiftUI.
