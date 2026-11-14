// A 5×7 pixel font for the wordmark and the Open Graph image, in the krysa's pixel style.
// It has only the glyphs those texts use. Drawing text from rectangles keeps the image
// the same wherever it is built, whatever fonts the machine has.

const glyphs: Readonly<Record<string, readonly string[]>> = {
  a: [".....", ".....", ".###.", "....#", ".####", "#...#", ".####"],
  b: ["#....", "#....", "####.", "#...#", "#...#", "#...#", "####."],
  c: [".....", ".....", ".####", "#....", "#....", "#....", ".####"],
  d: ["....#", "....#", ".####", "#...#", "#...#", "#...#", ".####"],
  e: [".....", ".....", ".###.", "#...#", "#####", "#....", ".####"],
  h: ["#....", "#....", "####.", "#...#", "#...#", "#...#", "#...#"],
  i: ["..#..", ".....", ".##..", "..#..", "..#..", "..#..", ".###."],
  k: ["#....", "#....", "#..#.", "#.#..", "##...", "#.#..", "#..#."],
  l: [".##..", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
  n: [".....", ".....", "####.", "#...#", "#...#", "#...#", "#...#"],
  o: [".....", ".....", ".###.", "#...#", "#...#", "#...#", ".###."],
  r: [".....", ".....", "#.##.", "##..#", "#....", "#....", "#...."],
  s: [".....", ".....", ".####", "#....", ".###.", "....#", "####."],
  t: [".#...", ".#...", "####.", ".#...", ".#...", ".#..#", "..##."],
  u: [".....", ".....", "#...#", "#...#", "#...#", "#..##", ".##.#"],
  v: [".....", ".....", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
  x: [".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
  "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
  " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
};

export const glyphHeight = 7;
const glyphWidth = 5;
const spacing = 1;

/** Width of `text` in pixels, without trailing spacing. */
export function textWidth(text: string): number {
  return text.length * (glyphWidth + spacing) - spacing;
}

/**
 * An SVG path that draws `text` with its top left corner at (`x`, `y`), one unit per
 * pixel. Each pixel overlaps its neighbours slightly, so no seams show when scaled.
 */
export function textPath(text: string, x = 0, y = 0): string {
  let path = "";
  [...text].forEach((character, index) => {
    const glyph = glyphs[character];
    if (glyph === undefined) {
      throw new Error(`The pixel font has no glyph for "${character}"`);
    }
    const left = x + index * (glyphWidth + spacing);
    glyph.forEach((row, rowIndex) => {
      [...row].forEach((cell, column) => {
        if (cell === "#") {
          path += `M${left + column} ${y + rowIndex}h1.02v1.02h-1.02z`;
        }
      });
    });
  });
  return path;
}
