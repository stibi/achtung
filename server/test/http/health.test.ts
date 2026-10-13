import { afterAll, describe, expect, it } from "vitest";
import { buildApp } from "../../src/http/app.ts";

describe("health endpoints", () => {
  const app = buildApp({ logLevel: "silent" });
  afterAll(() => app.close());

  it.each(["/healthz", "/readyz"])("%s returns ok", async (path) => {
    const response = await app.inject({ method: "GET", url: path });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ status: "ok" });
  });
});
