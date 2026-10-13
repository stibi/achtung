import { z } from "zod";

// Alertmanager webhook payload, version 4:
// https://prometheus.io/docs/alerting/latest/configuration/#webhook_config
const labelSet = z.record(z.string(), z.string());

const alert = z.object({
  status: z.enum(["firing", "resolved"]),
  labels: labelSet,
  annotations: labelSet,
  startsAt: z.iso.datetime({ offset: true }),
  endsAt: z.iso.datetime({ offset: true }),
  generatorURL: z.string(),
  fingerprint: z.string().min(1),
});

export const webhookPayload = z.object({
  version: z.literal("4"),
  groupKey: z.string(),
  truncatedAlerts: z.number().int().nonnegative().default(0),
  status: z.enum(["firing", "resolved"]),
  receiver: z.string(),
  groupLabels: labelSet,
  commonLabels: labelSet,
  commonAnnotations: labelSet,
  externalURL: z.string(),
  alerts: z.array(alert),
});

type WebhookPayload = z.infer<typeof webhookPayload>;
export type WebhookAlert = WebhookPayload["alerts"][number];
