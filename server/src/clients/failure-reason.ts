/**
 * Why a call to another system failed, as only a code or a name, never the error's
 * message: fetch's messages can quote the URL, and with it credentials.
 */
export function reasonOf(error: unknown): string {
  const cause = (error as { cause?: { code?: unknown } }).cause;
  if (typeof cause?.code === "string") {
    return cause.code;
  }
  return error instanceof Error ? error.name : "unknown error";
}
