import type { APIRoute } from "astro";
import sharp from "sharp";
import { nestedIcon } from "../lib/icon.ts";
import { glyphHeight, textPath, textWidth } from "../lib/pixel-font.ts";

// The Open Graph image, 1200×630: the app icon, the wordmark and the line under it,
// all drawn from shapes, so it looks the same on any build machine.
const width = 1200;
const height = 630;
const green = "#29df2b";

function pixelText(text: string, x: number, y: number, scale: number, fill: string): string {
  return `<path transform="translate(${x} ${y}) scale(${scale})" d="${textPath(text)}" fill="${fill}" shape-rendering="crispEdges"/>`;
}

const wordScale = 13;
const lineScale = 5;
const left = 440;
const lineGap = 40;
const blockHeight = glyphHeight * (wordScale + lineScale) + lineGap;
const wordTop = Math.round((height - blockHeight) / 2);
const lineTop = wordTop + glyphHeight * wordScale + lineGap;

if (left + textWidth("achtunk8s") * wordScale > width - 60) {
  throw new Error("The wordmark doesn't fit the Open Graph image");
}

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">
  <defs>
    <radialGradient id="glow" cx=".25" cy=".5" r=".6">
      <stop offset="0" stop-color="${green}" stop-opacity=".18"/>
      <stop offset="1" stop-color="${green}" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="${width}" height="${height}" fill="#050605"/>
  <rect width="${width}" height="${height}" fill="url(#glow)"/>
  ${nestedIcon(40, (height - 380) / 2, 380)}
  ${pixelText("achtun", left, wordTop, wordScale, "#ffffff")}
  ${pixelText("k8s", left + (textWidth("achtun") + 1) * wordScale, wordTop, wordScale, green)}
  ${pixelText("alerts deserve an inbox", left, lineTop, lineScale, "#b8c2b8")}
</svg>`;

export const GET: APIRoute = async () => {
  const png = await sharp(Buffer.from(svg)).png().toBuffer();
  return new Response(new Uint8Array(png), { headers: { "Content-Type": "image/png" } });
};
