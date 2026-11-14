# Plan: dead man's switch and alert handover to an agent

Status: **planned, not started** (written 2026-11-14). Two features researched together.
Neither has an ADR yet; each phase below that changes the API, the schema or the
deployment needs one, and the user's OK, before it is built (AGENTS.md).

Prerequisite for both: the change stream (`GET /api/events`, ADR 0019). Idea 2 builds
on it directly.

---

## 1. Dead man's switch outside the cluster Achtung runs in

### Problem

Achtung, its Alertmanagers and Grafana IRM's heartbeats (ADR 0012) all tell you that
something *fired*. Nothing tells you when the whole cluster Achtung runs in, or the path
out of it, is gone: then nothing fires, and silence looks like health. We want a witness
that lives outside that cluster and alerts when expected signals *stop*.

### Decisions

- **Outbound only.** The monitored side pushes heartbeats out to the witness. The
  witness never connects in. A missed heartbeat already means "can't reach the outside",
  so nothing is lost compared with probing from outside, and nothing is exposed. (Achtung
  is internal-only behind the Tailscale gateway; a public probe could not reach it anyway.)
- **The watcher is watched.** The witness itself sends a heartbeat to Grafana Cloud IRM,
  which is the final, vendor-run watcher outside all our systems. IRM heartbeats: an
  integration has a heartbeat URL and an interval; a missed beat opens an alert group, the
  next beat resolves it.
- **Alerts go to IRM**, through an IRM webhook integration, so paging, escalation and
  on-call stay in one place. Optionally a second, independent channel (ntfy or Pushover)
  for the case where IRM itself is the problem.
- **Senders talk to the witness directly, not through Achtung**, so an outage of the
  cluster still triggers the alerts. Achtung is one sender among others.
- **Deep heartbeats.** Achtung doesn't only say "alive". It sends a signed payload:
  - each cluster's Alertmanager `Watchdog` seen within the last N minutes,
  - time of the last ingest,
  - which Alertmanagers it can reach.

  The witness can then alert on "Achtung is up but the cdx alert path is broken", not
  only "everything is dead": an end-to-end check of the alert path.
- **Achtung shows the switches.** A "Dead man's switches" section on Home: each check,
  its last heartbeat and deadline, read from the witness (a read, like IRM heartbeats in
  ADR 0012). Needs an ADR and a Home API change.

### Options (ranked)

**B. Cloudflare Durable Object per check: chosen.**

- A Durable Object (DO) is a single, globally unique actor with its own storage. One DO
  per check (`check id` → DO).
- Heartbeat: `POST /beat/<check>` (HMAC-signed) stores the payload and calls
  `setAlarm(now + interval + grace)`. A DO has one alarm; `setAlarm` replaces it, so each
  beat pushes the deadline out.
- Missed: `alarm()` runs, marks the check `missing` and posts to the IRM webhook (and
  the backup channel). When a beat comes back, it posts the resolve.
- Deep payload rules (Watchdog age, last ingest age) are evaluated on each beat; a bad
  payload alerts even though the beat arrived.
- `alarm()` is at-least-once with retries (exponential backoff from 2 s, up to 6
  tries): the handler must be idempotent (store "alerted for deadline X" before/after
  posting, IRM dedupes by a stable alert id).
- Watching the witness: a Worker cron trigger (every minute) sends the IRM heartbeat
  only after checking the DOs answer (e.g. a canary DO beaten by the cron itself).
- Read API for Achtung's Home: `GET /checks` (token-protected), listing state, last
  beat, deadline, last payload.
- Config: checks defined in code/config (id, interval, grace, rules, IRM route), deployed
  with wrangler. No UI.
- Why: practically free, nothing to run or patch, outside the cluster, AWS and the home
  Proxmox; timers are native.

**A. Grafana IRM heartbeats only: fallback / first step.**

- One IRM webhook integration with a heartbeat per check; senders ping the heartbeat
  URL. Nothing new to run; works today. Achtung could manage and display them via the
  IRM API (it already holds a token).
- Limits: only "a URL was pinged within an interval", no payload rules, one vendor.

**C. NATS JetStream quorum witness: the ambitious option, kept for later.**

- Three nodes in three failure domains (e.g. Hetzner/Fly, AWS eu-central-1, home
  Proxmox), R3 streams, Raft.
- Each check is a KV key written with a per-message TTL (NATS ≥ 2.11, `Nats-TTL`).
  On expiry JetStream writes a subject delete marker (`SubjectDeleteMarkerTTL`; KV "limit
  markers") with `Nats-Marker-Reason`; a consumer on the markers fires the alert.
- Expiry only happens with quorum, so one node's network blip can't false-alarm; a
  node in the minority knows it is isolated and can raise "witness partitioned".
- Costs: three machines to run. The per-message TTL applies on create (rewriting the
  key does not renew it), so beats are new entries. Bugs in exactly this feature were
  fixed in 2.11.7 and 2.11.10: pin a recent version.
- Worth it for the engineering, or if the witness later carries more than heartbeats.

**Rejected**

- Kafka: no timers. "Alert when something did *not* happen" means a windowing stream
  processor on top; far too heavy for a replicated timer.
- Grafana Synthetic Monitoring: public probes can't reach an internal-only Achtung; a
  private probe inside the cluster defeats the point.

### Phases

1. Witness Worker + DOs (option B): beat, alarm → IRM webhook, cron self-heartbeat to
   IRM, `GET /checks`. Own directory (e.g. `witness/`) or own repo, decided then.
2. First senders: a CronJob/sidecar per cluster beating plain liveness; then Achtung's
   deep payload (needs an ADR: what Achtung computes and how it signs).
3. Home section in Achtung (server read + macOS UI), ADR + API change.
4. Optional backup channel (ntfy/Pushover).

### Open questions

- Witness code in this repo or its own? (It deploys to Cloudflare, not the cluster.)
- Signing: per-sender HMAC secrets in the Worker's secrets, rotated how?
- Which checks first, and their intervals and grace.

### Sources

- Grafana IRM integrations, heartbeat:
  https://grafana.com/docs/grafana-cloud/alerting-and-irm/irm/integrations/configure-integrations/
- Grafana IRM contact point, heartbeat:
  https://grafana.com/docs/grafana/next/alerting/configure-notifications/manage-contact-points/integrations/configure-irm/
- Cloudflare Durable Objects alarms: https://developers.cloudflare.com/durable-objects/api/alarms
- NATS 2.11 what's new: https://docs.nats.io/release-notes/whats_new/whats_new_211
- NATS KV TTL and limits: https://docs.nats.io/learn/key-value/ttl-and-limits
- NATS server 2.11 release: https://nats.io/blog/nats-server-2.11-release/

---

## 2. "Investigate with agent": hand an alert over to a coding agent

### Problem

Today the macOS client has "Copy for Agent" (`AgentReport.markdown(for:events:now:)`):
the user copies the alert as Markdown and pastes it into an agent by hand. We want one
button that starts an investigation by a Claude Code agent running in herdr on the
user's agent VM, and brings the findings back into Achtung.

### Decision: the VM pulls, it isn't pushed to

The server records an investigation request; a worker on the agent VM, connected to the
change stream, picks it up. Reasons:

- no inbound connections to the VM, and no SSH keys or VM access inside the Mac app;
- any client can press the button (a future iOS app too);
- the server never needs to reach the VM; the worker's connection is outbound over the
  tailnet, like any client's.

### Flow

1. **Button** "Investigate with Agent" in the alert detail →
   `POST /api/occurrences/{id}/investigations`. The server stores a row `requested` in a
   new `investigations` table and publishes a `changed: investigations` event (new
   `ChangeKind`).
2. **Worker** `achtung-agent-worker`, a systemd user service on the VM, holds
   `/api/events` open. On a request it claims it with a conditional update
   (`requested` → `running`, so two workers can't both take it), then:
   - `herdr workspace create` (or `herdr worktree create`) labelled `achtung-<id>`;
   - `herdr agent start inv-<id> --kind claude --pane <root pane> -- <restricted profile args>`;
   - `herdr agent prompt inv-<id> "<fixed template + AgentReport markdown>"`.
3. **The agent investigates** read-only: kubie + `kubectl get/describe/logs`, Loki and
   Prometheus via the Grafana MCP. It ends by sending its findings as Markdown:
   `PUT /api/occurrences/{id}/investigations/{iid}` (`done` + body), or `failed`.
4. **Result**: the server stores it and publishes the event; the alert detail shows the
   Markdown on every client, plus an optional "Investigation finished" notification.
5. **Steering**: it's a real herdr pane, so the user can open it and take over the
   conversation mid-way (the advantage over headless `claude -p`).

### Guardrails

- Alert labels and annotations are **untrusted input** (many systems write them). Fixed
  prompt template, alert data clearly fenced as data; a restricted Claude profile:
  read-only tools, no writes to clusters, Vault, Terraform or git remotes; the iac STOP
  rule applies; never silence or unsilence alerts.
- One active investigation per occurrence; a time limit after which the worker marks it
  `timed out` and closes the pane; an optional cap on concurrent investigations.
- Results are Markdown rendered as text (no HTML), size-limited.
- No real hostnames in anything committed (fixtures, examples).

### Where Rex fits

Rex on the VM has a built-in Tailscale listener (`rex server tailscale on`) and a
self-describing control API (`session.create`, `block.event`, `data.connect` to stream a
block's output, events). It could be a push transport (Mac → VM, no SSH), but its wire
protocol isn't documented as public and the remote-access docs are thin; a Swift client
would have to shell out to the `rex` CLI. So: not the transport. Optional convenience
later: open the investigation's pane in Rex, and an "Open in Rex" link in the alert
detail.

Alternatives considered: Mac → SSH → `herdr --machine` (push; puts VM access in the app),
server → webhook to a VM receiver (needs inbound to the VM).

### Phases

1. **VM only**: a hand-run script that takes an occurrence id, fetches it, builds the
   prompt and starts the herdr/Claude pane with the restricted profile. Prove useful
   investigations before any UI.
2. **Server**: `investigations` table (id, occurrence id, state
   `requested|running|done|failed|timed_out`, requested/started/finished times, result
   Markdown), the endpoints, the `investigations` change kind. ADR + user OK (API and
   schema change).
3. **Worker** as a systemd user service (the phase 1 script plus the stream and claim).
4. **macOS**: the button, state and result view in the alert detail; notification.
5. Optional: Rex link.

### Open questions

- Which Claude profile/permissions exactly (settings file with an allowlist), and which
  MCP servers it gets.
- Where the worker lives: this repo (`agent-worker/`) or the dotfiles.
- Should a finished investigation be visible in search (ADR 0017)?

### Sources

- herdr CLI: `herdr --skill`, `herdr agent|workspace|worktree --help` (0.9.5)
- Rex docs: https://www.superlogical.com/rex/docs/
