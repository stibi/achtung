# 0019: A change stream, so clients needn't wait for their next poll

- Status: accepted
- Date: 2026-11-10

## Context

The macOS client polls every 30 seconds (ADR 0013). A new alert therefore takes up to
half a minute to show up and to notify, and a silence set from one Mac shows on another
only at its next poll. The architecture planned Server-Sent Events from the start.

## Decision

- **`GET /api/events` is a Server-Sent Events stream of what changed, not of data.** It
  opens with `ready`, then sends `changed` with `{"kind": …}`:
  - `occurrences`: a notification was ingested, or the reconciler resolved occurrences
    as vanished (ADR 0014);
  - `silences`: a silence was set or ended through Achtung, also one that failed, since
    Alertmanager may have taken part of it;
  - `settings`: the ignored alert names changed (ADR 0011).

  The client re-reads through the API as it does on a poll. The stream adds no second
  shape of the data to keep in step, and a client that misses an event loses nothing
  that the next read doesn't bring.
- **`ready` means "re-read everything".** Nothing is replayed: there are no event ids and
  no `Last-Event-ID`. A reconnecting client re-reads once, which is what polling does
  anyway. The `retry` field asks clients to wait 5 s before reconnecting.
- **Polling stays, slower.** Silences changed in Alertmanager itself, and the Home
  view's Alertmanager and IRM reads, are not announced. The client keeps polling while
  the stream is open, at a longer interval, and goes back to 30 s when it is closed.
- **In memory, in one process** (`services/changes.ts`). Achtung runs as one replica.
  With more, each would announce only its own changes; Postgres `LISTEN/NOTIFY` is the
  step then. It needs a dedicated connection, which the shared Postgres can ill spare
  today.
- **Bounded and kept open:** at most 100 streams at once, another gets 503; a comment
  line every 20 s keeps idle streams open through proxies; a client that stops reading is
  dropped once 64 KiB wait for it, rather than buffered for without end; closing the
  server ends every stream and its connection (or drops it after a second), so shutdown
  doesn't wait for clients.
- **No authentication**, like every other route (ADR 0002). The stream says only that
  something changed.

## Consequences

- A new alert reaches a connected client within its debounce, not up to 30 s later.
- The gateway in front of Achtung must not time a stream out. Envoy's default route
  timeout is 15 s, so the route needs `timeouts.request: 0s` for `/api/events` (a
  deployment change). Without it, clients reconnect every 15 s and still work.
- Every client re-reads after each change. At alert volume this is a few reads per
  minute per client; the 30 s caches of Alertmanager reads keep it off Alertmanager.
