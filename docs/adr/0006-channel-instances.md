# 0006: Channels belong to an instance, named in the ingest URL

- Status: accepted
- Date: 2026-11-08

## Context

Several Kubernetes clusters send alerts, each through its own Alertmanager, and each one
routes to several channels. The client should show them as a tree: the sending system on
top, its channels underneath. The server stored only the adapter type (`alertmanager`)
and one global channel name, so it could not tell which cluster a channel's alerts come
from, and two clusters could not each have a `devops` channel.

## Decision

- **A channel belongs to an instance:** the sending system, typically one cluster's
  Alertmanager. A channel name is unique within its instance. Instance names follow the
  channel name rule.
- **The instance is named in the URL:** `POST /ingest/{source}/{instance}/{channel}`,
  created on first use like a channel. We did not derive it from the payload (for
  Alertmanager, `externalURL`): that value is often a pod address unless someone set it,
  and changing it would split a channel's history.
- **The old URL without an instance keeps working**, and so does
  `GET /api/channels/{slug}/occurrences`. Both are deprecated. A name resolves to the one
  named instance that has a channel of that name. A name no named instance has, or
  several have, means the channel in the `default` instance, which is created if needed. Channels from before
  this change are in `default`.
- The client API adds `instance` to `Channel` and `Occurrence`, and
  `GET /api/instances/{instance}/channels/{slug}/occurrences` addresses a channel fully.

## Consequences

- Moving existing channels to a named instance is an operator step, not a migration,
  because the name is deployment-specific:
  `UPDATE channels SET instance = '<name>' WHERE instance = 'default';`.
  Old URLs keep reaching the moved channels by name, so a sender can switch to the new
  URL later without losing a resolve. The old URL's lookup locks the channel rows it
  reads, so the move can run while notifications arrive.
- **Switch a sender to the new URL before another instance reuses one of its channel
  names.** Once two named instances have a name, the old URL resolves it to `default`,
  so a sender still on the old URL would split off a new channel there, and its open
  occurrences would never resolve. For a rollout: deploy, move the existing channels,
  switch the sender, and only then add other instances. The old URL's lookup locks the channel rows it
  reads, so the move can run while notifications arrive.
- **Switch a sender to the new URL before another instance reuses one of its channel
  names.** Once two named instances have a name, the old URL resolves it to `default`,
  so a sender still on the old URL would split off a new channel there and its open
  occurrences would never resolve. For a rollout: deploy, move the existing channels,
  switch the sender, and only then add other instances.
- A typo in the instance segment creates a stray instance, as one in the channel segment
  creates a stray channel (ADR 0005).
- The old routes can be removed once no sender or client uses them.
