import { loadConfig } from "./config.ts";
import { buildApp } from "./http/app.ts";

const config = loadConfig();
const app = buildApp({ logLevel: config.logLevel });

async function shutdown(signal: NodeJS.Signals): Promise<void> {
  app.log.info({ signal }, "shutting down");
  await app.close();
}

process.once("SIGTERM", (signal) => void shutdown(signal));
process.once("SIGINT", (signal) => void shutdown(signal));

await app.listen({ host: config.host, port: config.port });
