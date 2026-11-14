import type { APIRoute, GetStaticPaths } from "astro";
import sharp from "sharp";
import { framePosters } from "../../lib/media.ts";

// A clip's first frame, shown before it plays, when the clip has no still of its own.
export const getStaticPaths = (() =>
  framePosters().map(({ name, gif }) => ({ params: { name }, props: { gif } }))) satisfies GetStaticPaths;

export const GET: APIRoute<{ gif: Buffer }> = async ({ props }) => {
  const webp = await sharp(props.gif, { pages: 1 }).webp({ quality: 82 }).toBuffer();
  return new Response(new Uint8Array(webp), { headers: { "Content-Type": "image/webp" } });
};
