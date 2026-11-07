import fastifySwagger from "@fastify/swagger";
import Fastify, { type FastifyInstance } from "fastify";
import {
  hasZodFastifySchemaValidationErrors,
  serializerCompiler,
  validatorCompiler,
} from "fastify-type-provider-zod";
import type { Config } from "../config.ts";
import type { SourceAdapter } from "../sources/source-adapter.ts";
import { type Inbox, registerApiRoutes } from "./api.ts";
import { registerHealthRoutes } from "./health.ts";
import { type Ingest, registerIngestRoutes } from "./ingest.ts";
import { openApiTransform, openApiTransformObject } from "./openapi.ts";

/** The use cases the routes call; src/main.ts binds them to the database. */
export type Services = Inbox & { readonly ingest: Ingest };

export interface AppOptions {
  readonly logLevel: Config["logLevel"] | "silent";
  readonly sources: readonly SourceAdapter[];
  readonly services: Services;
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

  // Zod route schemas validate requests and responses, and generate the OpenAPI document.
  app.setValidatorCompiler(validatorCompiler);
  app.setSerializerCompiler(serializerCompiler);
  app.setErrorHandler((error, _request, reply) => {
    if (hasZodFastifySchemaValidationErrors(error)) {
      return reply.code(400).send({ error: error.message });
    }
    // Client errors Fastify raises itself, e.g. a body that is not JSON: keep the reason.
    const status = (error as { statusCode?: number }).statusCode;
    if (status !== undefined && status >= 400 && status < 500) {
      return reply.code(status).send({ error: (error as Error).message });
    }
    throw error;
  });
  app.register(fastifySwagger, {
    openapi: {
      info: {
        title: "Achtung",
        description: "Self-hosted alert inbox. No authentication: see ADR 0002.",
        version: "0.1.0",
      },
    },
    transform: openApiTransform,
    transformObject: openApiTransformObject,
  });

  // Registered as a plugin, after swagger, so swagger sees every route.
  app.register(async (routes) => {
    registerHealthRoutes(routes, options.checkReady);
    registerIngestRoutes(routes, options.sources, options.services.ingest);
    registerApiRoutes(routes, options.services);
  });
  return app;
}
