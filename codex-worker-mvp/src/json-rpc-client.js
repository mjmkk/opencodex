import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { createInterface } from "node:readline";

const DEFAULT_REQUEST_TIMEOUT_MS = 120000;

export class JsonRpcClient extends EventEmitter {
  constructor(options = {}) {
    super();
    this.command = options.command ?? "codex";
    this.args = options.args ?? ["app-server"];
    this.cwd = options.cwd ?? process.cwd();
    this.env = options.env ?? process.env;
    this.requestTimeoutMs = options.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;

    this.child = null;
    this.started = false;
    this.nextId = 1;
    this.pending = new Map();
  }

  async start() {
    if (this.started) {
      return;
    }

    this.child = spawn(this.command, this.args, {
      cwd: this.cwd,
      env: this.env,
      stdio: ["pipe", "pipe", "pipe"],
    });

    this.child.stderr.on("data", (chunk) => {
      const message = chunk.toString("utf8").trim();
      if (message.length > 0) {
        this.emit("stderr", message);
      }
    });

    this.child.on("error", (error) => {
      this.#failAllPending(error);
      this.emit("error", error);
    });

    this.child.on("exit", (code, signal) => {
      const reason = new Error(`app-server exited (code=${code ?? "null"}, signal=${signal ?? "null"})`);
      this.#failAllPending(reason);
      this.started = false;
      this.emit("exit", { code, signal });
    });

    const rl = createInterface({ input: this.child.stdout });
    rl.on("line", (line) => {
      this.#handleLine(line);
    });

    this.started = true;
  }

  async stop() {
    if (!this.child) {
      return;
    }
    this.child.kill();
    this.child = null;
    this.started = false;
  }

  request(method, params) {
    const id = this.nextId;
    this.nextId += 1;

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`JSON-RPC request timeout: ${method}`));
      }, this.requestTimeoutMs);

      this.pending.set(id, {
        resolve,
        reject,
        timeout,
        method,
      });

      this.#send({ id, method, params });
    });
  }

  notify(method, params) {
    this.#send({ method, params });
  }

  respond(id, result) {
    this.#send({ id, result });
  }

  respondError(id, code, message, data = undefined) {
    const error = data === undefined ? { code, message } : { code, message, data };
    this.#send({ id, error });
  }

  #send(message) {
    if (!this.child || !this.child.stdin.writable) {
      throw new Error("app-server stdin is not writable");
    }
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  #handleLine(line) {
    const trimmed = line.trim();
    if (trimmed.length === 0) {
      return;
    }

    let message;
    try {
      message = JSON.parse(trimmed);
    } catch (error) {
      this.emit("protocolError", {
        kind: "invalid_json",
        line: trimmed,
        error,
      });
      return;
    }

    const hasId = Object.prototype.hasOwnProperty.call(message, "id");
    const hasMethod = typeof message.method === "string";

    if (hasId && !hasMethod) {
      const pending = this.pending.get(message.id);
      if (!pending) {
        this.emit("protocolError", {
          kind: "unknown_response_id",
          message,
        });
        return;
      }

      clearTimeout(pending.timeout);
      this.pending.delete(message.id);

      if (Object.prototype.hasOwnProperty.call(message, "error")) {
        pending.reject(new Error(`RPC ${pending.method} failed: ${JSON.stringify(message.error)}`));
        return;
      }

      pending.resolve(message.result);
      return;
    }

    if (hasId && hasMethod) {
      this.emit("request", message);
      return;
    }

    if (!hasId && hasMethod) {
      this.emit("notification", message);
      return;
    }

    this.emit("protocolError", {
      kind: "unexpected_message_shape",
      message,
    });
  }

  #failAllPending(error) {
    for (const [id, pending] of this.pending.entries()) {
      clearTimeout(pending.timeout);
      pending.reject(error);
      this.pending.delete(id);
    }
  }
}
