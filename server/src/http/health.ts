import type { FastifyInstance } from "fastify";

/** Liveness, and readiness: `checkReady` throws when a dependency is unavailable. */
export function registerHealthRoutes(app: FastifyInstance, checkReady: () => Promise<void>): void {
  app.get("/healthz", () => ({ status: "ok" }));
  app.get("/readyz", async (request, reply) => {
    try {
      await checkReady();
      return { status: "ok" };
    } catch (error) {
      request.log.warn({ err: error }, "not ready");
      return reply.code(503).send({ status: "unavailable" });
    }
  });
}
