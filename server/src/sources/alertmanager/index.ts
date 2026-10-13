import { z } from "zod";
import type { SourceAdapter } from "../source-adapter.ts";
import { toIncomingAlert } from "./map.ts";
import { webhookPayload } from "./payload.ts";

export const alertmanagerSource: SourceAdapter = {
  id: "alertmanager",
  parse(body) {
    const result = webhookPayload.safeParse(body);
    if (!result.success) {
      return { ok: false, error: z.prettifyError(result.error) };
    }
    return {
      ok: true,
      alerts: result.data.alerts.map(toIncomingAlert),
      truncatedAlerts: result.data.truncatedAlerts,
    };
  },
};
