import { loadConfig } from "./config.js";
import { createHttpServer } from "./http-server.js";
import { JsonRpcClient } from "./json-rpc-client.js";
import { SqliteStore } from "./sqlite-store.js";
import { WorkerService } from "./worker-service.js";

function log(level, message, extra = undefined) {
  const payload = {
    level,
    ts: new Date().toISOString(),
    message,
    ...(extra ? { extra } : {}),
  };
  // eslint-disable-next-line no-console
  console.log(JSON.stringify(payload));
}

async function main() {
  const config = loadConfig();

  const rpc = new JsonRpcClient({
    command: config.rpc.command,
    args: config.rpc.args,
    cwd: config.rpc.cwd,
  });

  const store = new SqliteStore({
    dbPath: config.dbPath,
    logger: {
      warn: (msg) => log("warn", msg),
      error: (msg, extra) => log("error", msg, extra),
    },
    eventPageLimit: config.eventRetention,
  });
  store.init();

  const service = new WorkerService({
    rpc,
    store,
    projectPaths: config.projectPaths,
    defaultProjectPath: config.defaultProjectPath,
    eventRetention: config.eventRetention,
    logger: {
      warn: (msg) => log("warn", msg),
      error: (msg, extra) => log("error", msg, extra),
    },
  });

  await service.init();

  const server = createHttpServer({
    service,
    authToken: config.authToken,
    logger: {
      error: (msg, extra) => log("error", msg, extra),
    },
  });

  await server.listen(config.port);

  log("info", "codex-worker-mvp started", {
    port: config.port,
    authEnabled: Boolean(config.authToken),
    defaultProjectPath: config.defaultProjectPath,
  });

  const shutdown = async (signal) => {
    log("info", "shutdown requested", { signal });
    try {
      await server.close();
      await service.shutdown();
      store.close();
      process.exit(0);
    } catch (error) {
      log("error", "shutdown failed", {
        error: error instanceof Error ? error.message : String(error),
      });
      process.exit(1);
    }
  };

  process.on("SIGINT", () => {
    shutdown("SIGINT");
  });
  process.on("SIGTERM", () => {
    shutdown("SIGTERM");
  });
}

main().catch((error) => {
  log("error", "worker bootstrap failed", {
    error: error instanceof Error ? error.message : String(error),
  });
  process.exit(1);
});
