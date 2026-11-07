import Fastify, { type FastifyInstance } from "fastify";
import type { Config } from "../config.ts";
import type { SourceAdapter } from "../sources/source-adapter.ts";
import { registerHealthRoutes } from "./health.ts";
import { type Ingest, registerIngestRoutes } from "./ingest.ts";

export interface AppOptions {
  readonly logLevel: Config["logLevel"] | "silent";
  readonly sources: readonly SourceAdapter[];
  readonly ingest: Ingest;
  readonly checkReady: () => Promise<void>;
  /** Where log lines go; stdout when absent. Tests pass a stream to assert on logs. */
  readonly logStream?: { write(line: string): void };
}

export function buildApp(options: AppOptions): FastifyInstance {
  const logger =
    options.logStream === undefined
      ? { level: options.logLevel }
      : { level: options.logLevel, stream: options.logStream };
  const app = Fastify({ logger });
  registerHealthRoutes(app, options.checkReady);
  registerIngestRoutes(app, options.sources, options.ingest);
  return app;
}
