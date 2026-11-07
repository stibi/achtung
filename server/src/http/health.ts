import type { FastifyInstance } from "fastify";

/** Liveness, and readiness: `checkReady` throws when a dependency is unavailable. */
export function registerHealthRoutes(app: FastifyInstance, checkReady: () => Promise<void>): void {
  // Probes for Kubernetes, not part of the client API, so left out of api/openapi.yaml.
  // Probes run every few seconds; logging each request would bury everything else. At
  // warn a failed readiness check still logs.
  const options = { schema: { hide: true }, logLevel: "warn" } as const;
  app.get("/healthz", options, () => ({ status: "ok" }));
  app.get("/readyz", options, async (request, reply) => {
    try {
      await checkReady();
      return { status: "ok" };
    } catch (error) {
      request.log.warn({ err: error }, "not ready");
      return reply.code(503).send({ status: "unavailable" });
    }
  });
}
