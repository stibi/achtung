// The app icon (macos/Icon/AppIcon.svg), the one source for the favicon, the touch icon
// and the Open Graph image.
import appIcon from "../../../macos/Icon/AppIcon.svg?raw";

export const iconSvg: string = appIcon;

/** The icon as an SVG element placed at (`x`, `y`) with the given size, to nest in another SVG. */
export function nestedIcon(x: number, y: number, size: number): string {
  const opening = /^<svg\b[^>]*>/.exec(appIcon);
  if (opening === null) {
    throw new Error("AppIcon.svg does not start with an <svg> element");
  }
  return appIcon.replace(opening[0], `<svg x="${x}" y="${y}" width="${size}" height="${size}" viewBox="0 0 1024 1024">`);
}
