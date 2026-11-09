import { z } from "zod";

// One instance's Alertmanager. The instance name is the one in the ingest URL (ADR 0006).
const alertmanagerSchema = z
  .object({
    url: z.url({ protocol: /^https?$/ }),
    username: z.string().min(1).optional(),
    password: z.string().min(1).optional(),
    // Its cluster's Grafana IRM integration, whose heartbeat Home shows (ADR 0012).
    irmIntegrationId: z
      .string()
      .regex(/^[A-Za-z0-9]{1,64}$/, "an IRM integration ID, e.g. CABC123")
      .optional(),
  })
  .strict()
  .refine((value) => (value.username === undefined) === (value.password === undefined), {
    message: "username and password go together",
  })
  .refine(({ url }) => withoutCredentialsIfURL(url), {
    message: "put credentials in username and password, not in the URL",
  });

// fetch refuses a URL with credentials and quotes it in its error, which would log them.
function withoutCredentialsIfURL(url: string): boolean {
  return !URL.canParse(url) || withoutCredentials(new URL(url));
}

function withoutCredentials(url: URL): boolean {
  return url.username === "" && url.password === "";
}

const alertmanagersSchema = z.record(
  z.string().regex(/^[a-z0-9][a-z0-9-]{0,62}$/, "an instance name"),
  alertmanagerSchema,
);

/** JSON text in an environment variable, validated by `schema`. */
function json<T extends z.ZodType>(schema: T) {
  return z
    .string()
    .transform((text, context) => {
      try {
        return JSON.parse(text) as unknown;
      } catch {
        context.addIssue({ code: "custom", message: "not valid JSON" });
        return z.NEVER;
      }
    })
    .pipe(schema);
}

// The only module allowed to read process.env (enforced by Biome).
const envSchema = z
  .object({
    HOST: z.string().min(1).default("0.0.0.0"),
    PORT: z.coerce.number().int().min(1).max(65_535).default(8080),
    LOG_LEVEL: z.enum(["fatal", "error", "warn", "info", "debug", "trace"]).default("info"),
    DATABASE_URL: z.url({ protocol: /^postgres(ql)?$/ }),
    // {"<instance>": {"url": "https://…", "username": "…", "password": "…"}}. Holds
    // credentials, so deployments set it from a secret (ADR 0008).
    ALERTMANAGERS: json(alertmanagersSchema).optional(),
    // Grafana IRM's API, e.g. https://oncall-prod-eu-west-0.grafana.net/oncall, and a token
    // for it: both or neither (ADR 0012). The token is a secret.
    IRM_API_URL: z
      .url({ protocol: /^https?$/ })
      .refine(withoutCredentialsIfURL, { message: "no credentials in the URL; use IRM_API_TOKEN" })
      .optional(),
    IRM_API_TOKEN: z.string().min(1).optional(),
  })
  .refine((env) => (env.IRM_API_URL === undefined) === (env.IRM_API_TOKEN === undefined), {
    message: "IRM_API_URL and IRM_API_TOKEN go together",
    path: ["IRM_API_TOKEN"],
  });

/** Where an instance's Alertmanager is, for silences (ADR 0008). */
interface AlertmanagerConfig {
  readonly url: string;
  readonly basicAuth: { readonly username: string; readonly password: string } | null;
  /** Its Grafana IRM integration, whose heartbeat Home shows (ADR 0012); null for none. */
  readonly irmIntegrationId: string | null;
}

export interface Config {
  readonly host: string;
  readonly port: number;
  readonly logLevel: z.infer<typeof envSchema>["LOG_LEVEL"];
  /** postgres://user:password@host:5432/database */
  readonly databaseUrl: string;
  /** By instance name. An instance without one can't be silenced. */
  readonly alertmanagers: ReadonlyMap<string, AlertmanagerConfig>;
  /** Grafana IRM's API, for the heartbeats on Home (ADR 0012); null when not configured. */
  readonly irm: { readonly url: string; readonly token: string } | null;
}

export function loadConfig(
  env: Readonly<Record<string, string | undefined>> = process.env,
): Config {
  const result = envSchema.safeParse(env);
  if (!result.success) {
    throw new Error(`Invalid configuration:\n${z.prettifyError(result.error)}`);
  }
  return {
    host: result.data.HOST,
    port: result.data.PORT,
    logLevel: result.data.LOG_LEVEL,
    databaseUrl: result.data.DATABASE_URL,
    alertmanagers: new Map(
      Object.entries(result.data.ALERTMANAGERS ?? {}).map(
        ([instance, { url, username, password, irmIntegrationId }]) => [
          instance,
          {
            url,
            basicAuth:
              username !== undefined && password !== undefined ? { username, password } : null,
            irmIntegrationId: irmIntegrationId ?? null,
          },
        ],
      ),
    ),
    irm: irmOf(result.data),
  };
}

function irmOf({ IRM_API_URL: url, IRM_API_TOKEN: token }: z.infer<typeof envSchema>) {
  return url !== undefined && token !== undefined ? { url, token } : null;
}
