import type { FastifyInstance } from "fastify";

/** Liveness, and readiness: `checkReady` throws when a dependency is unavailable. */
export function registerHealthRoutes(app: FastifyInstance, checkReady: () => Promise<void>): void {
  // Probes for Kubernetes, not part of the client API, so left out of api/openapi.yaml.
  const schema = { hide: true };
  app.get("/healthz", { schema }, () => ({ status: "ok" }));
  app.get("/readyz", { schema }, async (request, reply) => {
    try {
      await checkReady();
      return { status: "ok" };
    } catch (error) {
      request.log.warn({ err: error }, "not ready");
      return reply.code(503).send({ status: "unavailable" });
    }
  });
}
