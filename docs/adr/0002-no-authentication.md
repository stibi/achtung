# 0002: No authentication or users (for now)

- Status: accepted
- Date: 2026-10-13

## Context

Achtung is open source from day one and anyone should be able to deploy their own
instance. Authentication (login, users, roles, tokens) adds a lot of scope before the
core product exists. The deployment is exposed through a Kubernetes ingress.

## Decision

- The application has no authentication, no authorization, no users and no login. That
  covers the ingest webhooks and the client API.
- An instance is shared. Anyone who can reach it sees every channel and alert, and
  acknowledging an alert affects everyone.
- "Read" and "last seen" state belongs to each client and is stored locally in the macOS
  app, not on the server. That is enough for "new since last time" without user
  identities.
- Access control is the operator's job and happens in front of the app: restricting the
  ingress (internal ingress class, IP allowlist, VPN or Tailscale only), or putting an
  authenticating proxy in front of it (oauth2-proxy, ingress basic auth).
- HTTP handling stays structured (Fastify hooks and plugins) so that authentication can
  be added later in one place without rewriting routes.

## Consequences

- **An ingress exposed to the internet without protection lets anyone read the alerts,
  which leak internal hostnames and topology, and lets anyone inject fake alerts.** The
  README and deployment docs must say this clearly.
- Read state does not sync between two Macs. This is acceptable for now.
- Adding users later means migrating acknowledgements to a per-user model and possibly
  moving read state to the server. That work will be done when it's needed and will get
  a new ADR.
