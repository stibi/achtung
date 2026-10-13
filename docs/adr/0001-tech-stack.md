# 0001: Tech stack

- Status: accepted
- Date: 2026-10-13

## Context

Achtung has a server, which ingests webhooks, stores alerts and serves an API, and a
native macOS client. Most of the code will be written by coding agents. Because of that,
the stack has to be mainstream (well represented in training data), strictly typed (so
mistakes surface at compile time), and checkable with a single command. The server runs
on Kubernetes, deployed by Flux and exposed through an ingress.

## Decision

**Server**
- TypeScript on the current Node.js LTS, ESM only, with the strictest compiler settings.
  Node runs the `.ts` sources directly using type stripping, so there is no build step and
  `tsc` only type-checks.
- **Fastify** as the HTTP framework. It is mature and Node-native, it has a built-in
  structured logger (pino), and it supports schema-based routes with OpenAPI
  generation. Hono was the alternative. Its main strength is running on many runtimes,
  which we don't need.
- **Zod** for all input validation, via `fastify-type-provider-zod`. The route schemas
  generate the OpenAPI spec.
- **PostgreSQL** for storage, with **Drizzle** for the schema, queries and migrations.
- **Server-Sent Events** to push realtime updates to clients. The traffic is
  server→client only, SSE is plain HTTP, and it works through ingresses without extra
  setup.
- Tooling: pnpm, Biome (lint and format), Vitest, and Testcontainers for Postgres. The
  quality tooling is covered in [ADR 0003](0003-quality-enforcement.md).

**Platform**
- GitHub for hosting, GitHub Actions for CI/CD, Dependabot for dependency updates.

**API contract**
- `api/openapi.yaml` is generated from the server routes and committed. CI fails if it is
  out of date. The Swift client is generated from it, so the two sides can't drift apart.

**Client**
- Swift 6 with strict concurrency checking, SwiftUI with `@Observable`, and the latest
  macOS only.
- XcodeGen (`project.yml`) instead of a committed `.xcodeproj`. Project files are
  unreadable and merge badly, and agents corrupt them.
- Logic lives in local Swift packages. The domain and API client packages have no UI
  dependency, so they build and test on Linux.
- `swift-openapi-generator` for the API client.

**Deployment**
- One container image. Kubernetes manifests (or a Helm chart) live in `deploy/`, and the
  Flux setup that deploys it lives in a separate infrastructure repository. Postgres is
  external (an operator or a managed instance).

## Consequences

- The server needs only a Linux machine and Docker. The macOS app target can only be
  built on a Mac, so agents running on Linux can't verify UI changes.
- Generating the OpenAPI spec from the code means server code defines the API. To change
  the API, change the routes and regenerate.
- Choosing Postgres over SQLite means running a database even for small installs, but
  the server can run as multiple replicas and fits the existing infrastructure.
