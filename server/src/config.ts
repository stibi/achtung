import { z } from "zod";

// The only module allowed to read process.env (enforced by Biome).
const envSchema = z.object({
  HOST: z.string().min(1).default("0.0.0.0"),
  PORT: z.coerce.number().int().min(1).max(65_535).default(8080),
  LOG_LEVEL: z.enum(["fatal", "error", "warn", "info", "debug", "trace"]).default("info"),
});

export interface Config {
  readonly host: string;
  readonly port: number;
  readonly logLevel: z.infer<typeof envSchema>["LOG_LEVEL"];
}

export function loadConfig(
  env: Readonly<Record<string, string | undefined>> = process.env,
): Config {
  const result = envSchema.safeParse(env);
  if (!result.success) {
    throw new Error(`Invalid configuration:\n${z.prettifyError(result.error)}`);
  }
  return { host: result.data.HOST, port: result.data.PORT, logLevel: result.data.LOG_LEVEL };
}
