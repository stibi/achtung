import {
  type AlertLink,
  type AlertState,
  type IncomingAlert,
  parseSeverity,
} from "../../domain/alert.ts";
import type { WebhookAlert } from "./payload.ts";

export function toIncomingAlert(alert: WebhookAlert): IncomingAlert {
  return {
    ...stateOf(alert),
    sourceKey: alert.fingerprint,
    severity: parseSeverity(alert.labels["severity"]),
    title: alert.labels["alertname"] ?? alert.fingerprint,
    summary: alert.annotations["summary"] ?? alert.annotations["description"] ?? null,
    labels: alert.labels,
    annotations: alert.annotations,
    startsAt: new Date(alert.startsAt),
    links: linksOf(alert),
  };
}

// A firing alert's endsAt is either the zero time or Alertmanager's resolve timeout
// estimate, so it is not an end. A resolved alert's endsAt is when it resolved.
function stateOf(alert: WebhookAlert): AlertState {
  return alert.status === "firing"
    ? { status: "firing", endsAt: null }
    : { status: "resolved", endsAt: new Date(alert.endsAt) };
}

function linksOf(alert: WebhookAlert): AlertLink[] {
  const links: AlertLink[] = [];
  if (alert.generatorURL !== "") {
    links.push({ kind: "source", url: alert.generatorURL });
  }
  const runbook = alert.annotations["runbook_url"];
  if (runbook !== undefined) {
    links.push({ kind: "runbook", url: runbook });
  }
  const dashboard = alert.annotations["dashboard_url"];
  if (dashboard !== undefined) {
    links.push({ kind: "dashboard", url: dashboard });
  }
  return links;
}
