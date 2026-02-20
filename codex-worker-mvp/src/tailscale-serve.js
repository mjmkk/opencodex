import { execFile as execFileCallback } from "node:child_process";
import { promisify } from "node:util";

const execFile = promisify(execFileCallback);
const DEFAULT_CLI_CANDIDATES = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "tailscale"];

function toErrorMessage(error) {
  if (!error) {
    return "unknown error";
  }
  if (error instanceof Error) {
    const stderr = typeof error.stderr === "string" ? error.stderr.trim() : "";
    if (stderr) {
      return `${error.message}: ${stderr}`;
    }
    return error.message;
  }
  return String(error);
}

export function normalizeServePath(value) {
  const raw = typeof value === "string" ? value.trim() : "";
  if (!raw || raw === "/") {
    return "/";
  }
  const withSlash = raw.startsWith("/") ? raw : `/${raw}`;
  return withSlash.endsWith("/") ? withSlash.slice(0, -1) : withSlash;
}

export function buildServeArgs({ service, path, target }) {
  const normalizedPath = normalizeServePath(path);
  const args = ["serve", "--bg"];
  if (typeof service === "string" && service.trim().length > 0) {
    args.push("--service", service.trim());
  }
  if (normalizedPath !== "/") {
    args.push("--set-path", normalizedPath);
  }
  args.push(target);
  return args;
}

async function runServe(exec, cliCandidates, args) {
  let lastError = null;
  for (const cli of cliCandidates) {
    try {
      await exec(cli, args);
      return { ok: true, cli };
    } catch (error) {
      lastError = error;
      if (error && error.code === "ENOENT") {
        continue;
      }
      return { ok: false, cli, error };
    }
  }
  return { ok: false, cli: cliCandidates[0] ?? "tailscale", error: lastError };
}

export async function ensureTailscaleServe({
  service,
  path,
  port,
  exec = execFile,
  cliCandidates = DEFAULT_CLI_CANDIDATES,
} = {}) {
  const target = `http://127.0.0.1:${port}`;
  const args = buildServeArgs({ service, path, target });
  const result = await runServe(exec, cliCandidates, args);

  if (!result.ok) {
    return {
      applied: false,
      service,
      path: normalizeServePath(path),
      target,
      error: toErrorMessage(result.error),
      cli: result.cli,
      args,
    };
  }

  return {
    applied: true,
    service,
    path: normalizeServePath(path),
    target,
    cli: result.cli,
    args,
  };
}
