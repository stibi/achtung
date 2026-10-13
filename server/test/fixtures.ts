import { readFileSync } from "node:fs";

export function loadFixture(source: string, name: string): unknown {
  const url = new URL(`./fixtures/${source}/${name}.json`, import.meta.url);
  return JSON.parse(readFileSync(url, "utf8"));
}
