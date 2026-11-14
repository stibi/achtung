import type { APIRoute } from "astro";
import { site } from "../site.ts";

export const GET: APIRoute = () =>
  new Response(`User-agent: *\nAllow: /\n\nSitemap: ${new URL("/sitemap-index.xml", site.url).href}\n`, {
    headers: { "Content-Type": "text/plain" },
  });
