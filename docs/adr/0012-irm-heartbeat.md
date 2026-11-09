# 0012: Home shows whether Grafana IRM receives each Alertmanager's heartbeat

- Status: accepted
- Date: 2026-11-09

## Context

Each Alertmanager fires a heartbeat alert, `grafana-irm-heartbeat` (a rule with
`expr: vector(1)`), and routes it about every 50 seconds to the heartbeat URL of its
cluster's Grafana IRM integration. When IRM stops receiving it, IRM opens an alert group
titled `OnCallHeartBeatMissing` on that integration, and pages. When the heartbeat comes
back, IRM resolves the group itself, typically about 2 minutes later.

The Home tile (ADR 0010) shows what an Alertmanager has open and whether its Watchdog
fires, but not whether paging works: the heartbeat can fire in Alertmanager and still not
reach IRM (a broken route, a rotated heartbeat URL, IRM's side). The user wants each tile
to close that loop. Since ADR 0011 the heartbeat alert itself is an ignored name, so the
counts don't show it either.

## Decision

- **Achtung reads IRM's alert groups:** `GET {IRM_API_URL}/api/v1/alert_groups/` with the
  integration's ID, `search=OnCallHeartBeatMissing` and `perpage=10`, newest first, with
  the header `Authorization: <token>` (the raw token, IRM's convention, no `Bearer`).
  IRM's public integrations API has no heartbeat status, and the heartbeat endpoints the
  IRM plugin uses are internal and undocumented. The alert groups are public, documented
  and read-only.
- **The title is the contract.** The latest group (by `created_at`, not trusting the
  order IRM lists them in) whose title, trimmed, is exactly `OnCallHeartBeatMissing` (IRM
  sends a trailing space) decides, and only groups of the integration count, should IRM
  ignore a filter. `search` matches titles that contain the name, so ten are read rather
  than one. Checked against the real IRM: `search` narrows the groups to the missed
  heartbeats, while `name`, which the first version used, is silently ignored, so the
  last missed heartbeat fell out of the ten behind the integration's other alerts. If
  IRM ever ignored `search` too, the same would happen.
  - none, or the latest is resolved: **receiving**, with the last missed heartbeat
    (`lastMissedFrom`, `lastMissedTo`: the group's start and resolve), if any;
  - the latest is `new`, `acknowledged` or `silenced`: **missing**, since the group
    opened. Acknowledging or silencing a group in IRM doesn't bring the heartbeat back;
    only IRM resolves it.
  - **unknown** until IRM has been read successfully.
- **Configuration:** `IRM_API_URL` and `IRM_API_TOKEN`, both or neither, from a secret;
  credentials inside the URL are rejected, as in `ALERTMANAGERS` (ADR 0008). Each
  `ALERTMANAGERS` entry may name its `irmIntegrationId`. A tile's `irm` is null when IRM
  isn't configured or the instance has no integration.
- **Cached like the Alertmanager reads** (`cachedRead`, ADR 0008 and 0010): per
  integration, at most once a minute, one read at a time. A failed read keeps the last
  good status and its time (`checkedAt`) and reports the error. IRM itself takes minutes to
  open a group or to resolve it, so a fresher read would add little.
  Home reads IRM in parallel with everything else, and the IRM client's 5-second timeout
  bounds how long it can wait.
- **Errors name no URL, token or response body**, only a code (`ECONNREFUSED`) or the
  HTTP status. Unlike Alertmanager's errors, the log doesn't get IRM's body either: an
  answer to a bad token is the likeliest one, and it can quote what was sent.

## Consequences

- **Green proves two things:** the Alertmanager fires the heartbeat (else IRM would open
  a group), and IRM has no open missed-heartbeat group for the integration. It doesn't
  prove that IRM would page anyone: escalation chains and schedules are IRM's.
- **The title is IRM's, not ours.** If Grafana renames `OnCallHeartBeatMissing`, no group
  matches and every tile shows "receiving", silently. The domain tests pin the title,
  and the ADR is where to look when IRM changes.
- **The status lags:** a heartbeat that stops shows as missing once IRM has opened its
  group and Achtung has read IRM since, up to a minute later; it shows as receiving again
  only once IRM resolves the group.
- The Home view costs one IRM request per integration per minute, whatever the number of
  clients. The token only needs to read alert groups.
- `cachedRead` now takes a read policy (how long a read is fresh, which error class is an
  expected failure), so the Alertmanager reads and IRM share it.
