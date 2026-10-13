import Fastify, { type FastifyInstance } from "fastify";
import type { Config } from "../config.ts";
import { registerHealthRoutes } from "./health.ts";

export interface AppOptions {
  readonly logLevel: Config["logLevel"] | "silent";
}

export function buildApp(options: AppOptions): FastifyInstance {
  const app = Fastify({ logger: { level: options.logLevel } });
  registerHealthRoutes(app);
  return app;
}
