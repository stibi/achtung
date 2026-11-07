// Shared by the global setup (which creates the template) and the tests (which clone it).
export const templateDatabase = "achtung_template";

/** The URL of another database on the same Postgres server. */
export function databaseUrl(serverUrl: string, database: string): string {
  const url = new URL(serverUrl);
  url.pathname = `/${database}`;
  return url.toString();
}
