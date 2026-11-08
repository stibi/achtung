import { z } from "zod";

// One instance's Alertmanager. The instance name is the one in the ingest URL (ADR 0006).
const alertmanagerSchema = z
  .object({
    url: z.url({ protocol: /^https?$/ }),
    username: z.string().min(1).optional(),
    password: z.string().min(1).optional(),
  })
  .strict()
  .refine((value) => (value.username === undefined) === (value.password === undefined), {
    message: "username and password go together",
  })
  // fetch refuses such a URL and quotes it in its error, which would log the password.
  .refine(({ url }) => !URL.canParse(url) || withoutCredentials(new URL(url)), {
    message: "put credentials in username and password, not in the URL",
  });

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
const envSchema = z.object({
  HOST: z.string().min(1).default("0.0.0.0"),
  PORT: z.coerce.number().int().min(1).max(65_535).default(8080),
  LOG_LEVEL: z.enum(["fatal", "error", "warn", "info", "debug", "trace"]).default("info"),
  DATABASE_URL: z.url({ protocol: /^postgres(ql)?$/ }),
  // {"<instance>": {"url": "https://…", "username": "…", "password": "…"}}. Holds
  // credentials, so deployments set it from a secret (ADR 0008).
  ALERTMANAGERS: json(alertmanagersSchema).optional(),
});

/** Where an instance's Alertmanager is, for silences (ADR 0008). */
interface AlertmanagerConfig {
  readonly url: string;
  readonly basicAuth: { readonly username: string; readonly password: string } | null;
}

export interface Config {
  readonly host: string;
  readonly port: number;
  readonly logLevel: z.infer<typeof envSchema>["LOG_LEVEL"];
  /** postgres://user:password@host:5432/database */
  readonly databaseUrl: string;
  /** By instance name. An instance without one can't be silenced. */
  readonly alertmanagers: ReadonlyMap<string, AlertmanagerConfig>;
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
        ([instance, { url, username, password }]) => [
          instance,
          {
            url,
            basicAuth:
              username !== undefined && password !== undefined ? { username, password } : null,
          },
        ],
      ),
    ),
  };
}
