function parseCsv(value) {
  if (!value) {
    return [];
  }
  return value
    .split(",")
    .map((item) => item.trim())
    .filter((item) => item.length > 0);
}

export function loadConfig(env = process.env) {
  const projectPaths = parseCsv(env.WORKER_PROJECT_PATHS);
  const defaultProjectPath = env.WORKER_DEFAULT_PROJECT?.trim() || projectPaths[0] || process.cwd();

  const command = env.CODEX_COMMAND?.trim() || "codex";
  const rawArgs = parseCsv(env.CODEX_APP_SERVER_ARGS);
  const args = rawArgs.length > 0 ? rawArgs : ["app-server"];

  const portRaw = env.PORT ?? "8787";
  const port = Number.parseInt(portRaw, 10);
  if (!Number.isInteger(port) || port <= 0) {
    throw new Error(`invalid PORT: ${portRaw}`);
  }

  const eventRetentionRaw = env.WORKER_EVENT_RETENTION ?? "2000";
  const eventRetention = Number.parseInt(eventRetentionRaw, 10);
  if (!Number.isInteger(eventRetention) || eventRetention < 100) {
    throw new Error(`invalid WORKER_EVENT_RETENTION: ${eventRetentionRaw}`);
  }

  return {
    port,
    authToken: env.WORKER_TOKEN?.trim() || null,
    projectPaths,
    defaultProjectPath,
    eventRetention,
    rpc: {
      command,
      args,
      cwd: env.WORKER_CWD?.trim() || process.cwd(),
    },
  };
}
