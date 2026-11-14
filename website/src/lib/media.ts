// Screenshots and clips of the app, from the repository's docs/media/ (the names are in
// docs/media/SHOTLIST.md). A shot that isn't captured yet shows as a placeholder, and the
// build lists it, so adding the file and rebuilding is all it takes.
import type { ImageMetadata } from "astro";

const directory = "../../../docs/media";
const stills = import.meta.glob<ImageMetadata>("../../../docs/media/*.png", { eager: true, import: "default" });
// The GIFs' bytes, read at build time for posters. Imported as data, not as files, so the
// GIFs themselves aren't published.
const animations = import.meta.glob<string>("../../../docs/media/*.gif", {
  eager: true,
  query: "?inline",
  import: "default",
});
const clips = import.meta.glob<string>("../../../docs/media/*.mp4", { eager: true, query: "?url", import: "default" });

export type Poster =
  /** The shot's still. */
  | { readonly kind: "still"; readonly image: ImageMetadata }
  /** The first frame of the clip's GIF, served by pages/posters/[name].webp.ts. */
  | { readonly kind: "frame"; readonly src: string; readonly gif: Buffer };

export type Shot =
  | { readonly kind: "clip"; readonly src: string; readonly poster: Poster | undefined }
  | { readonly kind: "still"; readonly image: ImageMetadata }
  | { readonly kind: "missing" };

const reported = new Set<string>();

function gifOf(name: string): Buffer | undefined {
  const dataUrl = animations[`${directory}/${name}.gif`];
  return dataUrl === undefined ? undefined : Buffer.from(dataUrl.slice(dataUrl.indexOf(",") + 1), "base64");
}

/** The clip `<name>.mp4`, or else the still `<name>.png`, or neither yet. */
export function shot(name: string): Shot {
  const still = stills[`${directory}/${name}.png`];
  const clip = clips[`${directory}/${name}.mp4`];
  if (clip !== undefined) {
    const gif = still === undefined ? gifOf(name) : undefined;
    const poster: Poster | undefined = still
      ? { kind: "still", image: still }
      : gif && { kind: "frame", src: `/posters/${name}.webp`, gif };
    return { kind: "clip", src: clip, poster };
  }
  if (still !== undefined) {
    return { kind: "still", image: still };
  }
  if (!reported.has(name)) {
    reported.add(name);
    console.warn(`[website] placeholder for docs/media/${name}.png: not captured yet`);
  }
  return { kind: "missing" };
}

/** Each clip that has a GIF but no still, for a poster from the GIF's first frame. */
export function framePosters(): { name: string; gif: Buffer }[] {
  return Object.keys(animations).flatMap((path) => {
    const name = path.slice(directory.length + 1, -".gif".length);
    const gif = gifOf(name);
    const needed = clips[`${directory}/${name}.mp4`] !== undefined && stills[`${directory}/${name}.png`] === undefined;
    return needed && gif ? [{ name, gif }] : [];
  });
}
