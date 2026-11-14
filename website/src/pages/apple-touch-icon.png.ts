import type { APIRoute } from "astro";
import sharp from "sharp";
import { iconSvg } from "../lib/icon.ts";

// iOS rounds the corners itself and wants no transparency: the icon's square, on black.
export const GET: APIRoute = async () => {
  const png = await sharp(Buffer.from(iconSvg))
    .extract({ left: 100, top: 100, width: 824, height: 824 })
    .resize(180, 180)
    .flatten({ background: "#000" })
    .png()
    .toBuffer();
  return new Response(new Uint8Array(png), { headers: { "Content-Type": "image/png" } });
};
