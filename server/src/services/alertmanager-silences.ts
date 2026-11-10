import { AlertmanagerError } from "../clients/alertmanager.ts";
import type { AlertmanagerAlert } from "../domain/overview.ts";
import type { AlertmanagerAlerts } from "./home.ts";
import type { Silences } from "./silences.ts";

/** What became of one of the alerts asked for. */
interface AlertSilenceResult {
  readonly fingerprint: string;
  /** The silence's end; null when the alert wasn't silenced. */
  readonly silencedUntil: Date | null;
  /** Why it wasn't; null when it was. */
  readonly error: string | null;
}

export type AlertmanagerSilenceResult =
  | { readonly kind: "silenced"; readonly alerts: readonly AlertSilenceResult[] }
  /** The instance has no Alertmanager configured. */
  | { readonly kind: "not-found" }
  /** Alertmanager was unreachable or refused. */
  | { readonly kind: "failed"; readonly reason: string };

/**
 * Silences each of the instance's alerts named by fingerprint, exactly, for
 * `durationSeconds`, as the alert's own silence would (ADR 0015, ADR 0016). Alerts that
 * aren't in Achtung can be silenced too: they are looked up in a fresh read of the
 * Alertmanager. One gone from it since is reported, not silenced.
 */
export async function silenceAlertmanagerAlerts(
  silences: Silences,
  alerts: AlertmanagerAlerts,
  instance: string,
  fingerprints: readonly string[],
  durationSeconds: number,
): Promise<AlertmanagerSilenceResult> {
  if (!silences.canSilence(instance)) {
    return { kind: "not-found" };
  }
  alerts.invalidate(instance);
  const reading = await alerts.read(instance);
  if (reading === null) {
    return { kind: "not-found" };
  }
  if (reading.error !== null || reading.last === null) {
    // The reason, not the message: a failed read's body can be a proxy's page naming hosts.
    return { kind: "failed", reason: reading.error?.reason ?? "Alertmanager was never read" };
  }
  const byFingerprint = new Map(reading.last.value.map((alert) => [alert.fingerprint, alert]));
  const found = [...new Set(fingerprints)].flatMap((fingerprint) => {
    const alert = byFingerprint.get(fingerprint);
    return alert === undefined ? [] : [alert];
  });
  let endsAt: Date;
  try {
    endsAt = await silences.createEach(instance, found.map(targetOf(instance)), durationSeconds);
  } catch (error) {
    if (error instanceof AlertmanagerError) {
      return { kind: "failed", reason: error.message };
    }
    throw error;
  } finally {
    alerts.invalidate(instance);
  }
  return {
    kind: "silenced",
    alerts: fingerprints.map((fingerprint) =>
      byFingerprint.has(fingerprint)
        ? { fingerprint, silencedUntil: endsAt, error: null }
        : { fingerprint, silencedUntil: null, error: "No longer in Alertmanager" },
    ),
  };
}

const targetOf = (instance: string) => (alert: AlertmanagerAlert) => ({
  labels: alert.labels,
  comment: `Silenced from Achtung: ${instance}, ${alert.labels["alertname"] ?? alert.fingerprint}`,
});
