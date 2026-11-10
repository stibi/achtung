"""A fake Achtung server with made-up alerts, for demos and screen recordings.

Serves the client API (api/openapi.yaml) on 127.0.0.1 from an in-memory scenario: three
instances with a few channels each, alerts that fired, resolved, reopened and were resent
over the last day, and older occurrences for their history. Times are relative to when
the server starts, and a few events lie ahead of it, so the inbox changes while it's
recorded: a critical alert fires after 45 seconds and another resolves after 2.5 minutes.
Silencing works, stops the alert's notifications and lasts until the server stops. No real hosts or data; every link points
at example.com. The ignored alert names can be edited, until the server stops; the demo
has no Home, so they change nothing else.

For trying notifications, two endpoints outside the API make things happen now:
  curl -X POST 'http://127.0.0.1:8790/demo/fire?count=1'   # new critical alerts
  curl -X POST http://127.0.0.1:8790/demo/resend           # resend the newest firing one

Usage: python3 demo-server.py [port]   (macos/scripts/demo.sh starts it with the app)
"""

import base64
import datetime
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

START = datetime.datetime.now(datetime.timezone.utc)
PAGE_SIZE = 50
REPEAT_MINUTES = 5  # how often Alertmanager repeats a firing alert


def at(minutes):
    """A time relative to the server's start: negative is in the past."""
    return START + datetime.timedelta(minutes=minutes)


def iso(time):
    return time.isoformat(timespec="milliseconds").replace("+00:00", "Z") if time else None


DESCRIPTIONS = {
    "CardAuthorisationsFailing": (
        "Card authorisations through the PSP fail since the 07:30 deploy of payments-api.\n"
        "Most failures are timeouts to the PSP gateway; see "
        "https://status.psp.example.com for its status."),
    "KubePodCrashLooping": (
        "Container api in pod notifications-7f9c4d-x2kq exits with code 137 (OOMKilled).\n"
        "Its memory limit is 256Mi."),
}


def alert(key, instance, channel, severity, title, summary, service, namespace="prod"):
    cluster = f"{instance}-1"
    slug = title.lower()
    annotations = {"summary": summary, "runbook_url": f"https://runbooks.example.com/{slug}"}
    if title in DESCRIPTIONS:
        annotations["description"] = DESCRIPTIONS[title]
        annotations["impact"] = "Customers see errors; on-call is paged."
    return {
        "sourceKey": key,
        "instance": instance,
        "channel": channel,
        "severity": severity,
        "title": title,
        "summary": summary,
        "labels": {
            "alertname": title,
            "severity": severity,
            "service": service,
            "namespace": namespace,
            "cluster": cluster,
            "job": service,
            "pod": f"{service}-7f9c4d-x2kq",
            "team": channel,
            "prometheus": "monitoring/k8s",
        },
        "annotations": annotations,
        "links": [
            {"kind": "source", "url": f"https://prometheus.example.com/graph?alert={title}"},
            {"kind": "runbook", "url": f"https://runbooks.example.com/{slug}"},
            {"kind": "dashboard", "url": f"https://grafana.example.com/d/{service}"},
        ],
    }


PAYMENTS = alert(
    "a1", "eu-prod", "payments", "critical", "CardAuthorisationsFailing",
    "7% of card authorisations failed over the last 10 minutes.", "payments-api")
QUEUE = alert(
    "a2", "eu-prod", "payments", "warning", "PaymentsQueueBacklog",
    "Settlement queue holds 12,400 messages, oldest 18 minutes old.", "settlement-worker")
LATENCY_EU = alert(
    "a3", "eu-prod", "payments", "warning", "HighLatencyP99",
    "p99 latency of payments-api is 1.8 s (threshold 1 s).", "payments-api")
CRASHLOOP = alert(
    "a4", "eu-prod", "platform", "warning", "KubePodCrashLooping",
    "Pod notifications-7f9c4d-x2kq is restarting 4 times every 10 minutes.", "notifications")
MEMORY = alert(
    "a5", "eu-prod", "platform", "warning", "NodeMemoryPressure",
    "Node worker-12 has less than 5% memory available.", "kubelet", "kube-system")
CERTIFICATE = alert(
    "a6", "eu-prod", "platform", "info", "CertificateExpiringSoon",
    "TLS certificate for api.example.com expires in 9 days.", "ingress", "ingress")
DISK = alert(
    "a7", "eu-prod", "platform", "critical", "DiskWillFillIn4Hours",
    "Volume data-logs-0 on worker-03 will be full in about 4 hours.", "loki", "logging")
REPLICATION = alert(
    "a8", "eu-prod", "databases", "warning", "PostgresReplicationLag",
    "Replica orders-db-2 is 45 s behind the primary.", "orders-db")
CONNECTIONS = alert(
    "a9", "eu-prod", "databases", "warning", "PostgresConnectionsHigh",
    "orders-db uses 92% of max_connections.", "orders-db")
BACKUP = alert(
    "a10", "eu-prod", "databases", "critical", "BackupJobFailed",
    "Nightly backup of orders-db did not complete.", "backup")
CHECKOUT_LATENCY = alert(
    "b1", "us-prod", "checkout", "critical", "CheckoutLatencyHigh",
    "Checkout p95 latency is 4.2 s for 5 minutes.", "checkout-api")
ERRORS = alert(
    "b2", "us-prod", "checkout", "critical", "HighErrorRate",
    "5xx rate above 5% for 10 minutes.", "checkout-api")
CART = alert(
    "b3", "us-prod", "checkout", "critical", "CartServiceDown",
    "cart-service has no healthy instances.", "cart-service")
TARGET = alert(
    "b4", "us-prod", "platform", "warning", "TargetDown",
    "2 of 6 node-exporter targets are down.", "node-exporter", "monitoring")
KAFKA = alert(
    "b5", "us-prod", "platform", "warning", "KafkaConsumerLag",
    "Consumer group order-events lags 85,000 messages.", "kafka", "streaming")
REPLICAS = alert(
    "b6", "us-prod", "platform", "info", "KubeDeploymentReplicasMismatch",
    "Deployment search-indexer runs 2 of 3 replicas.", "search-indexer")
FLAKY = alert(
    "c1", "staging", "ci", "info", "FlakyTestRate",
    "12% of test runs on main were retried in the last hour.", "ci", "ci")
RUNNER = alert(
    "c2", "staging", "ci", "warning", "BuildRunnerOffline",
    "Build runner mac-runner-2 hasn't checked in for 15 minutes.", "ci-runners", "ci")

# Each occurrence: its alert and the events that change its state, in minutes relative to
# the start. Events ahead of the start happen while the demo runs; an occurrence appears
# with its first event. Resends aren't listed: like the server (ADR 0009), `events` adds
# one for every hour an occurrence keeps firing without another event.
SCENARIO = [
    (PAYMENTS, [("fired", -35), ("resolved", 2.5)]),
    (QUEUE, [("fired", -26 * 60), ("resolved", -25 * 60)]),
    (QUEUE, [("fired", -200)]),
    (LATENCY_EU, [("fired", -500), ("resolved", -470)]),
    (CRASHLOOP, [("fired", -2 * 24 * 60), ("resolved", -2 * 24 * 60 + 25)]),
    (CRASHLOOP, [("fired", -95), ("resolved", -60)]),
    (MEMORY, [("fired", -720), ("resolved", -690)]),
    (CERTIFICATE, [("fired", -170)]),
    (DISK, [("fired", -15 * 60), ("resolved", -14 * 60)]),
    (REPLICATION, [("fired", -180), ("resolved", -150), ("reopened", -40)]),
    (CONNECTIONS, [("fired", -600), ("resolved", -560)]),
    (BACKUP, [("fired", -380)]),
    (CHECKOUT_LATENCY, [("fired", 0.75)]),
    (ERRORS, [("fired", -3 * 24 * 60), ("resolved", -3 * 24 * 60 + 40)]),
    (ERRORS, [("fired", -1000), ("resolved", -980)]),
    (CART, [("fired", -260), ("resolved", -245)]),
    (TARGET, [("fired", -55)]),
    # Ended while silenced (that silence has expired since): Alertmanager never sent the
    # resolve, so Achtung resolved it itself once it was gone (ADR 0014).
    (KAFKA, [("fired", -440), ("vanished", -400)]),
    (REPLICAS, [("fired", -900), ("resolved", -860)]),
    (FLAKY, [("fired", -120), ("resolved", -100)]),
    (RUNNER, [("fired", -30)]),
]
# A channel with nothing in it yet, as a new receiver URL would create.
EMPTY_CHANNELS = [("us-prod", "search")]
# Occurrence id -> (since, until). The backup was silenced before the demo started: it's
# known and being worked on. Alertmanager sends nothing for a silenced alert.
SILENCED = {12: (at(-300), at(3 * 60))}
RESEND_AFTER = datetime.timedelta(hours=1)


def kind_of(kind):
    """The API's event kind: a "vanished" event is a resolve Achtung recorded itself because
    the alert was gone from its Alertmanager (ADR 0014); its cause says so."""
    return "resolved" if kind == "vanished" else kind


def events(occurrence_id, now):
    """(id, kind, time) of everything recorded up to `now`, oldest first."""
    scenario = sorted(SCENARIO[occurrence_id - 1][1], key=lambda event: event[1])
    recorded = [(kind, at(minutes)) for kind, minutes in scenario if at(minutes) <= now]
    if recorded and recorded[-1][0] not in ("resolved", "vanished"):
        # Notifications arrive until the alert is silenced; each one an hour or more after
        # the last event records a resend.
        since, until = SILENCED.get(occurrence_id, (None, None))
        notified_until = since if since and until > now else now
        time = recorded[-1][1] + RESEND_AFTER
        while time <= notified_until:
            recorded.append(("resent", time))
            time += RESEND_AFTER
    return [(occurrence_id * 1000 + n, kind, time) for n, (kind, time) in enumerate(recorded)]


def occurrence(occurrence_id, now):
    """The occurrence as the server describes it at `now`, or None before its first event."""
    alert_fields = SCENARIO[occurrence_id - 1][0]
    recorded = events(occurrence_id, now)
    if not recorded:
        return None
    first, last = recorded[0][2], recorded[-1]
    resolved_at = last[2] if last[1] in ("resolved", "vanished") else None
    vanished = last[1] == "vanished"
    since, until = SILENCED.get(occurrence_id, (None, None))
    silenced = until is not None and until > now
    notified_until = resolved_at or (min(since, now) if silenced else now)
    if vanished:
        # As ADR 0014 has it: notifications stopped (the alert was silenced), it was gone
        # from Alertmanager 5 minutes before Achtung resolved it, and Achtung waited 10
        # minutes after the last notification before even looking.
        notified_until = resolved_at - datetime.timedelta(minutes=16)
    repeats = max(int((notified_until - first).total_seconds() // (REPEAT_MINUTES * 60)), 0)
    last_received = first + datetime.timedelta(minutes=repeats * REPEAT_MINUTES)
    return {
        "id": occurrence_id,
        "instance": alert_fields["instance"],
        "channel": alert_fields["channel"],
        "source": "alertmanager",
        "sourceKey": alert_fields["sourceKey"],
        "status": "resolved" if resolved_at else "firing",
        "severity": alert_fields["severity"],
        "title": alert_fields["title"],
        "summary": alert_fields["summary"],
        "labels": alert_fields["labels"],
        "annotations": alert_fields["annotations"],
        "links": alert_fields["links"],
        # Alertmanager reports the start a little before the first notification.
        "startsAt": iso(first - datetime.timedelta(seconds=30)),
        "endsAt": iso(resolved_at - datetime.timedelta(minutes=5) if vanished else resolved_at),
        "firstReceivedAt": iso(first),
        "lastReceivedAt": iso(last_received if vanished else max(last_received, last[2])),
        "lastEventAt": iso(last[2]),
        "lastEventKind": kind_of(last[1]),
        # A vanished resolve came with no notification.
        "notificationCount": repeats + 1 + (1 if resolved_at and not vanished else 0),
        "silencedUntil": iso(until) if silenced else None,
    }


def occurrences(now, instance=None, channel=None, status=None):
    """Newest change first, in the server's (lastEventAt, id) order."""
    found = []
    for occurrence_id in range(1, len(SCENARIO) + 1):
        described = occurrence(occurrence_id, now)
        if described is None:
            continue
        if instance and (described["instance"], described["channel"]) != (instance, channel):
            continue
        if status and described["status"] != status:
            continue
        found.append(described)
    return sorted(found, key=lambda o: (o["lastEventAt"], o["id"]), reverse=True)


def page(items, cursor):
    """One page and the cursor of the next: here simply the offset, encoded."""
    offset = int(base64.urlsafe_b64decode(cursor).decode()) if cursor else 0
    end = offset + PAGE_SIZE
    next_cursor = base64.urlsafe_b64encode(str(end).encode()).decode() if end < len(items) else None
    return {"occurrences": items[offset:end], "nextCursor": next_cursor}


def channels(now):
    found = {(a["instance"], a["channel"]): [] for a, _ in SCENARIO}
    for instance, channel in EMPTY_CHANNELS:
        found[(instance, channel)] = []
    for described in occurrences(now):
        found[(described["instance"], described["channel"])].append(described)
    return {
        "channels": [
            {
                "instance": instance,
                "slug": channel,
                "firing": sum(1 for o in listed if o["status"] == "firing"),
                "lastEventAt": max((o["lastEventAt"] for o in listed), default=None),
            }
            for (instance, channel), listed in sorted(found.items())
        ]
    }


def detail(occurrence_id, now):
    described = occurrence(occurrence_id, now) if 1 <= occurrence_id <= len(SCENARIO) else None
    if described is None:
        return None
    others = [
        o for o in occurrences(now)
        if o["id"] != occurrence_id
        and (o["instance"], o["channel"], o["sourceKey"])
        == (described["instance"], described["channel"], described["sourceKey"])
    ]
    history = [
        {
            "id": event_id,
            "kind": kind_of(kind),
            "cause": "vanished" if kind == "vanished" else None,
            "recordedAt": iso(time),
        }
        for event_id, kind, time in events(occurrence_id, now)
    ]
    others.sort(key=lambda o: o["startsAt"], reverse=True)
    return {"occurrence": described, "events": history, "otherOccurrences": others[:20]}


IGNORED = ["InfoInhibitor", "Watchdog"]  # the ignored alert names (Settings)


def set_ignored(body):
    names = body.get("names")
    if not isinstance(names, list) or len(names) > 200:
        return 400, {"error": "names must be a list of at most 200 alert names"}
    trimmed = [name.strip() if isinstance(name, str) else "" for name in names]
    if any(not name or len(name) > 200 for name in trimmed):
        return 400, {"error": "An alert name must have 1 to 200 characters"}
    IGNORED[:] = sorted(set(trimmed))
    return 200, {"names": IGNORED}


def matching(items, query):
    """The search parameters (q, label, severity, instance), like the server (ADR 0017)."""
    text = (query.get("q", [""])[0] or "").strip().lower()
    labels = [entry.split("=", 1) for entry in query.get("label", []) if "=" in entry]
    severities = query.get("severity", [])
    instance = query.get("instance", [None])[0]

    def matches(item):
        haystack = [item["title"], item.get("summary") or "", *item["labels"], *item["labels"].values()]
        return (
            (not text or any(text in part.lower() for part in haystack))
            and all(item["labels"].get(name) == value for name, value in labels)
            and (not severities or item["severity"] in severities)
            and (instance is None or item["instance"] == instance)
        )

    return [item for item in items if matches(item)]


def get(path, query, now):
    cursor = query.get("cursor", [None])[0]
    status = query.get("status", [None])[0]
    if path == "/api/channels":
        return 200, channels(now)
    if path == "/api/settings/ignored-alerts":
        return 200, {"names": IGNORED}
    if any("=" not in entry or entry.startswith("=") for entry in query.get("label", [])):
        return 400, {"error": "A label filter is name=value"}
    if path == "/api/occurrences":
        return 200, page(matching(occurrences(now, status=status), query), cursor)
    if match := re.fullmatch(r"/api/instances/([^/]+)/channels/([^/]+)/occurrences", path):
        instance, channel = match.groups()
        if not any((c["instance"], c["slug"]) == (instance, channel)
                   for c in channels(now)["channels"]):
            return 404, {"error": f"Channel {instance}/{channel} not found"}
        return 200, page(matching(occurrences(now, instance, channel, status), query), cursor)
    if match := re.fullmatch(r"/api/occurrences/(\d+)", path):
        found = detail(int(match.group(1)), now)
        return (200, found) if found else (404, {"error": "Occurrence not found"})
    return 404, {"error": "Not found"}


FIRED_ON_DEMAND = [
    ("eu-prod", "payments", "PaymentsApiDown", "payments-api answers 503 on every request.",
     "payments-api"),
    ("us-prod", "checkout", "CheckoutErrorBudgetBurn", "Checkout burns its error budget 14x.",
     "checkout-api"),
    ("eu-prod", "databases", "PostgresPrimaryDown", "orders-db primary is unreachable.",
     "orders-db"),
    ("us-prod", "platform", "NodeNotReady", "Node worker-21 has been NotReady for 5 minutes.",
     "kubelet"),
    ("eu-prod", "platform", "IngressCertificateExpired", "TLS certificate for shop.example.com "
     "expired.", "ingress"),
]


def fire(count, now):
    """Adds `count` new critical occurrences firing now; returns their ids."""
    minutes = (now - START).total_seconds() / 60
    ids = []
    for n in range(count):
        instance, channel, title, summary, service = FIRED_ON_DEMAND[
            (len(SCENARIO) + n) % len(FIRED_ON_DEMAND)]
        key = f"d{len(SCENARIO) + 1}"
        SCENARIO.append((alert(key, instance, channel, "critical", title, summary, service),
                         [("fired", minutes)]))
        ids.append(len(SCENARIO))
    return 200, {"fired": ids}


def resend(now):
    """Records a resend now on the newest firing occurrence, as an hour's quiet would."""
    firing = occurrences(now, status="firing")
    if not firing:
        return 404, {"error": "Nothing is firing"}
    occurrence_id = firing[0]["id"]
    SCENARIO[occurrence_id - 1][1].append(("resent", (now - START).total_seconds() / 60))
    return 200, {"resent": occurrence_id}


def silence(occurrence_id, body, now):
    described = occurrence(occurrence_id, now) if 1 <= occurrence_id <= len(SCENARIO) else None
    if described is None:
        return 404, {"error": "Occurrence not found"}
    seconds = body.get("durationSeconds")
    if not isinstance(seconds, int) or not 60 <= seconds <= 30 * 24 * 3600:
        return 400, {"error": "durationSeconds must be between 60 and 2592000"}
    SILENCED[occurrence_id] = (now, now + datetime.timedelta(seconds=seconds))
    return 200, occurrence(occurrence_id, now)


def unsilence(occurrence_id, now):
    if not 1 <= occurrence_id <= len(SCENARIO) or occurrence(occurrence_id, now) is None:
        return 404, {"error": "Occurrence not found"}
    SILENCED.pop(occurrence_id, None)
    return 200, occurrence(occurrence_id, now)


class DemoAPI(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 (http.server's naming)
        url = urlparse(self.path)
        self.reply(*get(url.path, parse_qs(url.query), datetime.datetime.now(datetime.timezone.utc)))

    def do_POST(self):  # noqa: N802
        url = urlparse(self.path)
        match = re.fullmatch(r"/api/occurrences/(\d+)/silence", url.path)
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        now = datetime.datetime.now(datetime.timezone.utc)
        if url.path == "/demo/fire":
            count = int(parse_qs(url.query).get("count", ["1"])[0])
            self.reply(*fire(max(1, min(count, 20)), now))
        elif url.path == "/demo/resend":
            self.reply(*resend(now))
        else:
            self.reply(*(silence(int(match.group(1)), body, now) if match else (404, {"error": "Not found"})))

    def do_DELETE(self):  # noqa: N802
        match = re.fullmatch(r"/api/occurrences/(\d+)/silence", urlparse(self.path).path)
        now = datetime.datetime.now(datetime.timezone.utc)
        self.reply(*(unsilence(int(match.group(1)), now) if match else (404, {"error": "Not found"})))

    def do_PUT(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        if urlparse(self.path).path == "/api/settings/ignored-alerts":
            self.reply(*set_ignored(body))
        else:
            self.reply(404, {"error": "Not found"})

    def reply(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass  # quiet: the demo's terminal shows only what demo.sh prints


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8790), DemoAPI).serve_forever()
