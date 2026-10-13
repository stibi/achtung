export type Severity = "critical" | "warning" | "info" | "unknown";

export interface AlertLink {
  readonly kind: "source" | "runbook" | "dashboard";
  readonly url: string;
}

/** A firing alert has no end yet; a resolved one always has one. */
export type AlertState =
  | { readonly status: "firing"; readonly endsAt: null }
  | { readonly status: "resolved"; readonly endsAt: Date };

/**
 * An alert as reported by a source, already mapped to Achtung's model. Sources produce
 * these; the core never sees source-specific payloads.
 */
export type IncomingAlert = AlertState & {
  /** Stable identity of the alert within its source, e.g. Alertmanager's fingerprint. */
  readonly sourceKey: string;
  readonly severity: Severity;
  readonly title: string;
  readonly summary: string | null;
  readonly labels: Readonly<Record<string, string>>;
  readonly annotations: Readonly<Record<string, string>>;
  /** Together with sourceKey identifies one occurrence; a re-fire after resolve is new. */
  readonly startsAt: Date;
  readonly links: readonly AlertLink[];
};

const severities: ReadonlySet<string> = new Set<Severity>(["critical", "warning", "info"]);

export function parseSeverity(value: string | undefined): Severity {
  const normalized = value?.trim().toLowerCase();
  if (normalized !== undefined && severities.has(normalized)) {
    return normalized as Severity;
  }
  return "unknown";
}
