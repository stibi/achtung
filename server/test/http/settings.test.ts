import type { FastifyInstance } from "fastify";
import { describe, expect, it } from "vitest";
import { getJson } from "../api.ts";
import { appWithDatabase } from "../app.ts";

const url = "/api/settings/ignored-alerts";

function put(app: FastifyInstance, body: unknown) {
  return app.inject({ method: "PUT", url, body: body as object });
}

describe("GET /api/settings/ignored-alerts", () => {
  it("starts with the names migration 0006 seeds, sorted", async () => {
    const { app } = await appWithDatabase();

    const { status, body } = await getJson(app, url);

    expect(status).toBe(200);
    expect(body).toEqual({ names: ["grafana-irm-heartbeat", "InfoInhibitor", "Watchdog"] });
  });
});

describe("PUT /api/settings/ignored-alerts", () => {
  it("replaces the list and answers with it as stored, sorted", async () => {
    const { app } = await appWithDatabase();

    const response = await put(app, { names: ["Watchdog", "KubeHpaMaxedOut", "CPUThrottling"] });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ names: ["CPUThrottling", "KubeHpaMaxedOut", "Watchdog"] });
    expect((await getJson(app, url)).body).toEqual(response.json());
  });

  it("trims the names and stores each once, case-sensitively", async () => {
    const { app } = await appWithDatabase();

    const response = await put(app, {
      names: ["  Watchdog ", "Watchdog", "watchdog", "\tHeartbeat\n", "Heartbeat"],
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ names: ["Heartbeat", "watchdog", "Watchdog"] });
  });

  it("empties the list", async () => {
    const { app } = await appWithDatabase();

    const response = await put(app, { names: [] });

    expect(response.json()).toEqual({ names: [] });
    expect((await getJson(app, url)).body).toEqual({ names: [] });
  });

  it.each([
    ["an empty name", { names: ["Watchdog", ""] }],
    ["a name of only whitespace", { names: ["   "] }],
    ["a name over 200 characters", { names: ["x".repeat(201)] }],
    ["over 200 names", { names: Array.from({ length: 201 }, (_, index) => `Alert${index}`) }],
    ["no list", {}],
    ["a name that isn't a string", { names: [42] }],
  ])("answers 400 for %s and keeps the list", async (_, body) => {
    const { app } = await appWithDatabase();

    const response = await put(app, body);

    expect(response.statusCode).toBe(400);
    expect(response.json()).toEqual({ error: expect.stringContaining("names") });
    expect((await getJson(app, url)).body).toEqual({
      names: ["grafana-irm-heartbeat", "InfoInhibitor", "Watchdog"],
    });
  });

  it("takes 200 names of 200 characters", async () => {
    const { app } = await appWithDatabase();
    const names = Array.from({ length: 200 }, (_, index) => `${index}`.padStart(200, "x"));

    const response = await put(app, { names });

    expect(response.statusCode).toBe(200);
    expect(response.json().names).toHaveLength(200);
  });
});
