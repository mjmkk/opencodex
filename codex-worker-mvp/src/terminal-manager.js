import { execFile as execFileCallback, spawn as spawnChildProcess } from "node:child_process";
import path from "node:path";
import { promisify } from "node:util";

import pty from "node-pty";

import { createId } from "./ids.js";

const execFile = promisify(execFileCallback);

const DEFAULTS = {
  shell: "/bin/zsh",
  idleTtlMs: 20 * 60 * 1000,
  maxSessions: 64,
  maxInputBytes: 32 * 1024,
  maxScrollbackBytes: 2 * 1024 * 1024,
  sweepIntervalMs: 10 * 1000,
  defaultCols: 80,
  defaultRows: 24,
  trackShellState: true,
};

const SHELL_STATE_MARKER = "__CW_STATE__";
const SHELL_BOOTSTRAP_DONE_MARKER = "__CW_BOOTSTRAP_DONE__";
const BOOTSTRAP_SILENT_MAX_MS = 15000;

function isPosixSpawnFailure(error) {
  const message = error instanceof Error ? error.message : String(error ?? "");
  return message.toLowerCase().includes("posix_spawnp failed");
}

function createPipeTerminalProcess(child) {
  const dataListeners = new Set();
  const exitListeners = new Set();
  const emitData = (chunk) => {
    const text = typeof chunk === "string" ? chunk : Buffer.from(chunk ?? "").toString("utf8");
    if (!text) {
      return;
    }
    for (const listener of dataListeners) {
      listener(text);
    }
  };
  const emitExit = (exitCode, signal) => {
    const payload = {
      exitCode: Number.isInteger(exitCode) ? exitCode : null,
      signal: signal ?? null,
    };
    for (const listener of exitListeners) {
      listener(payload);
    }
  };

  child.stdout?.on("data", emitData);
  child.stderr?.on("data", emitData);
  child.on("exit", emitExit);

  return {
    pid: Number.isInteger(child.pid) ? child.pid : -1,
    supportsShellStateHooks: false,
    transportMode: "pipe",
    onData(handler) {
      dataListeners.add(handler);
    },
    onExit(handler) {
      exitListeners.add(handler);
    },
    write(data) {
      if (!child.stdin?.destroyed) {
        child.stdin.write(data);
      }
    },
    resize() {
      // pipe 回退模式不支持 PTY resize
    },
    kill() {
      if (!child.killed) {
        child.kill("SIGTERM");
        const timer = setTimeout(() => {
          if (!child.killed) {
            child.kill("SIGKILL");
          }
        }, 1500);
        timer.unref?.();
      }
    },
  };
}

function toFiniteInt(value, fallback, min, max = Number.MAX_SAFE_INTEGER) {
  const parsed =
    typeof value === "number" && Number.isFinite(value)
      ? Math.trunc(value)
      : Number.parseInt(String(value), 10);
  if (!Number.isInteger(parsed)) {
    return fallback;
  }
  if (parsed < min) {
    return min;
  }
  if (parsed > max) {
    return max;
  }
  return parsed;
}

function normalizeTerminalSize(colsRaw, rowsRaw, fallbackCols, fallbackRows) {
  return {
    cols: toFiniteInt(colsRaw, fallbackCols, 10, 500),
    rows: toFiniteInt(rowsRaw, fallbackRows, 5, 300),
  };
}

function createTerminalError(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

export class TerminalManager {
  /**
   * @param {Object} [options]
   * @param {string} [options.shell]
   * @param {number} [options.idleTtlMs]
   * @param {number} [options.maxSessions]
   * @param {number} [options.maxInputBytes]
   * @param {number} [options.maxScrollbackBytes]
   * @param {number} [options.sweepIntervalMs]
   * @param {boolean} [options.trackShellState=true]
   * @param {boolean} [options.autoSweep=true]
   * @param {() => number} [options.now]
   * @param {{spawn: Function}} [options.ptyAdapter]
   * @param {Function} [options.childProcessSpawner]
   * @param {(pid: number) => Promise<boolean>} [options.hasChildProcessChecker]
   * @param {Object} [options.logger]
   */
  constructor(options = {}) {
    this.shell = typeof options.shell === "string" && options.shell.trim().length > 0
      ? options.shell.trim()
      : DEFAULTS.shell;
    this.idleTtlMs = toFiniteInt(options.idleTtlMs, DEFAULTS.idleTtlMs, 0);
    this.maxSessions = toFiniteInt(options.maxSessions, DEFAULTS.maxSessions, 1);
    this.maxInputBytes = toFiniteInt(options.maxInputBytes, DEFAULTS.maxInputBytes, 1);
    this.maxScrollbackBytes = toFiniteInt(options.maxScrollbackBytes, DEFAULTS.maxScrollbackBytes, 1024);
    this.sweepIntervalMs = toFiniteInt(options.sweepIntervalMs, DEFAULTS.sweepIntervalMs, 100);
    this.trackShellState = options.trackShellState !== false;
    this.autoSweep = options.autoSweep !== false;
    this.now = typeof options.now === "function" ? options.now : () => Date.now();
    this.ptyAdapter = options.ptyAdapter ?? pty;
    this.childProcessSpawner = options.childProcessSpawner ?? spawnChildProcess;
    this.hasChildProcessChecker = options.hasChildProcessChecker ?? ((pid) => this.#hasChildProcesses(pid));
    this.logger = options.logger ?? console;

    /** @type {Map<string, any>} */
    this.sessionsById = new Map();
    /** @type {Map<string, string>} */
    this.sessionIdByThreadId = new Map();
    this.sweepRunning = false;
    this.sweepTimer = null;
    if (this.autoSweep) {
      this.sweepTimer = setInterval(() => {
        this.#sweepIdleSessions().catch((error) => {
          const message = error instanceof Error ? error.message : String(error);
          this.logger?.warn?.(`[terminal] idle sweep failed: ${message}`);
        });
      }, this.sweepIntervalMs);
      this.sweepTimer.unref?.();
    }
  }

  shutdown() {
    if (this.sweepTimer) {
      clearInterval(this.sweepTimer);
      this.sweepTimer = null;
    }
    for (const sessionId of [...this.sessionsById.keys()]) {
      this.closeSession(sessionId, { reason: "shutdown", force: true });
    }
  }

  /**
   * 手动触发一次空闲会话扫描（用于测试/诊断）
   *
   * @returns {Promise<void>}
   */
  async sweepIdleSessionsOnce() {
    await this.#sweepIdleSessions();
  }

  /**
   * @param {Object} params
   * @param {string} params.threadId
   * @param {string} params.cwd
   * @param {number} [params.cols]
   * @param {number} [params.rows]
   * @returns {{ session: Object; reused: boolean }}
   */
  openSession(params) {
    const threadId = typeof params.threadId === "string" ? params.threadId.trim() : "";
    const cwd = typeof params.cwd === "string" ? params.cwd.trim() : "";
    if (!threadId) {
      throw createTerminalError("TERMINAL_INVALID_INPUT", "threadId 不能为空");
    }
    if (!cwd) {
      throw createTerminalError("TERMINAL_INVALID_INPUT", "cwd 不能为空");
    }

    const existingSessionId = this.sessionIdByThreadId.get(threadId);
    if (existingSessionId) {
      const existing = this.sessionsById.get(existingSessionId);
      if (existing && existing.status === "running") {
        this.#touchSession(existing);
        return {
          session: this.#toSessionSnapshot(existing),
          reused: true,
        };
      }
      this.sessionIdByThreadId.delete(threadId);
    }

    if (this.sessionsById.size >= this.maxSessions) {
      throw createTerminalError("TERMINAL_LIMIT_REACHED", `终端会话已达上限 ${this.maxSessions}`);
    }

    const { cols, rows } = normalizeTerminalSize(
      params.cols,
      params.rows,
      DEFAULTS.defaultCols,
      DEFAULTS.defaultRows
    );

    const terminalEnv = {
      ...process.env,
      TERM: "xterm-256color",
      COLORTERM: "truecolor",
      PROMPT_EOL_MARK: "",
    };

    let ptyProcess = null;
    const ptyArgCandidates = this.#resolvePrimaryPtyArgCandidates();
    let lastPtySpawnError = null;
    for (const shellArgs of ptyArgCandidates) {
      try {
        ptyProcess = this.ptyAdapter.spawn(this.shell, shellArgs, {
          name: "xterm-256color",
          cwd,
          cols,
          rows,
          env: terminalEnv,
        });
        ptyProcess.supportsShellStateHooks = true;
        ptyProcess.transportMode = "pty";
        if (JSON.stringify(shellArgs) !== JSON.stringify(ptyArgCandidates[0])) {
          this.logger?.warn?.(
            `[terminal] node-pty recovered with alternate args: shell=${this.shell}, args=${JSON.stringify(
              shellArgs
            )}, cwd=${cwd}`
          );
        }
        break;
      } catch (error) {
        lastPtySpawnError = error;
        if (!isPosixSpawnFailure(error)) {
          const message = error instanceof Error ? error.message : String(error);
          throw createTerminalError("TERMINAL_OPEN_FAILED", `启动终端失败: ${message}`);
        }
      }
    }

    if (!ptyProcess) {
      try {
        const fallbackArgs = this.#resolveFallbackShellArgs();
        const child = this.childProcessSpawner(this.shell, fallbackArgs, {
          cwd,
          env: terminalEnv,
          stdio: ["pipe", "pipe", "pipe"],
        });
        ptyProcess = createPipeTerminalProcess(child);
        this.logger?.warn?.(
          `[terminal] node-pty spawn failed, fallback to pipe mode: shell=${this.shell}, args=${JSON.stringify(
            fallbackArgs
          )}, cwd=${cwd}`
        );
      } catch (fallbackError) {
        const root = fallbackError ?? lastPtySpawnError;
        const message = root instanceof Error ? root.message : String(root);
        throw createTerminalError("TERMINAL_OPEN_FAILED", `启动终端失败: ${message}`);
      }
    }

    const createdAt = this.#nowIso();
    const session = {
      sessionId: createId("term"),
      threadId,
      cwd,
      shell: this.shell,
      pid: ptyProcess.pid,
      cols,
      rows,
      status: "running",
      createdAt,
      lastActiveAt: createdAt,
      exitCode: null,
      signal: null,
      nextSeq: 0,
      outputFrames: [],
      outputBytes: 0,
      exitFrame: null,
      clients: new Set(),
      listeners: new Map(),
      supportsShellStateHooks: ptyProcess.supportsShellStateHooks === true,
      transportMode: ptyProcess.transportMode === "pipe" ? "pipe" : "pty",
      foregroundBusy: false,
      backgroundJobs: 0,
      shellStateCarry: "",
      bootstrapFilterCarry: "",
      suppressBootstrapNoise: this.trackShellState && ptyProcess.supportsShellStateHooks === true,
      bootstrapStartedAtMs: this.now(),
      pty: ptyProcess,
    };

    ptyProcess.onData((data) => {
      this.#handleOutput(session, data);
    });
    ptyProcess.onExit((result) => {
      this.#handleExit(session, result);
    });

    this.sessionsById.set(session.sessionId, session);
    this.sessionIdByThreadId.set(threadId, session.sessionId);
    this.#installShellStateHooks(session);
    this.logger?.info?.(
      `[terminal] session opened: sessionId=${session.sessionId}, threadId=${threadId}, cwd=${cwd}, pid=${session.pid}`
    );

    return {
      session: this.#toSessionSnapshot(session),
      reused: false,
    };
  }

  /**
   * @param {string} threadId
   * @returns {Object|null}
   */
  getSessionByThreadId(threadId) {
    const sessionId = this.sessionIdByThreadId.get(threadId);
    if (!sessionId) {
      return null;
    }
    const session = this.sessionsById.get(sessionId);
    if (!session) {
      this.sessionIdByThreadId.delete(threadId);
      return null;
    }
    return this.#toSessionSnapshot(session);
  }

  /**
   * @param {string} sessionId
   * @returns {Object|null}
   */
  getSessionById(sessionId) {
    const session = this.sessionsById.get(sessionId);
    if (!session) {
      return null;
    }
    return this.#toSessionSnapshot(session);
  }

  /**
   * @param {Object} params
   * @param {string} params.sessionId
   * @param {string} params.clientId
   * @param {(event: Object) => void} params.onEvent
   * @param {number|null|undefined} params.fromSeq
   * @returns {{ session: Object; replay: Object[] }}
   */
  attachClient(params) {
    const session = this.sessionsById.get(params.sessionId);
    if (!session) {
      throw createTerminalError("TERMINAL_SESSION_NOT_FOUND", `终端会话不存在: ${params.sessionId}`);
    }
    if (typeof params.onEvent !== "function") {
      throw createTerminalError("TERMINAL_INVALID_INPUT", "onEvent 必须是函数");
    }

    const replay = this.#collectReplay(session, params.fromSeq);
    session.clients.add(params.clientId);
    session.listeners.set(params.clientId, params.onEvent);
    this.#touchSession(session);
    return {
      session: this.#toSessionSnapshot(session),
      replay,
    };
  }

  /**
   * @param {string} sessionId
   * @param {string} clientId
   */
  detachClient(sessionId, clientId) {
    const session = this.sessionsById.get(sessionId);
    if (!session) {
      return;
    }
    session.clients.delete(clientId);
    session.listeners.delete(clientId);
    this.#touchSession(session);
    if (session.status !== "running" && session.clients.size === 0) {
      this.#cleanupSession(session, "detached");
    }
  }

  /**
   * @param {string} sessionId
   * @param {string} data
   */
  writeInput(sessionId, data) {
    const session = this.sessionsById.get(sessionId);
    if (!session) {
      throw createTerminalError("TERMINAL_SESSION_NOT_FOUND", `终端会话不存在: ${sessionId}`);
    }
    if (session.status !== "running") {
      throw createTerminalError("TERMINAL_SESSION_EXITED", `终端会话已结束: ${sessionId}`);
    }
    if (typeof data !== "string" || data.length === 0) {
      throw createTerminalError("TERMINAL_INVALID_INPUT", "输入不能为空");
    }
    if (Buffer.byteLength(data, "utf8") > this.maxInputBytes) {
      throw createTerminalError("TERMINAL_INVALID_INPUT", "输入内容过长");
    }
    session.pty.write(data);
    this.#touchSession(session);
  }

  /**
   * @param {string} sessionId
   * @param {number} colsRaw
   * @param {number} rowsRaw
   * @returns {Object}
   */
  resizeSession(sessionId, colsRaw, rowsRaw) {
    const session = this.sessionsById.get(sessionId);
    if (!session) {
      throw createTerminalError("TERMINAL_SESSION_NOT_FOUND", `终端会话不存在: ${sessionId}`);
    }

    if (session.status !== "running") {
      throw createTerminalError("TERMINAL_SESSION_EXITED", `终端会话已结束: ${sessionId}`);
    }

    const { cols, rows } = normalizeTerminalSize(colsRaw, rowsRaw, session.cols, session.rows);
    session.cols = cols;
    session.rows = rows;
    session.pty.resize(cols, rows);
    this.#touchSession(session);
    this.logger?.info?.(
      `[terminal] session resized: sessionId=${session.sessionId}, cols=${cols}, rows=${rows}`
    );
    return this.#toSessionSnapshot(session);
  }

  /**
   * @param {string} sessionId
   * @param {Object} [options]
   * @param {string} [options.reason]
   * @param {boolean} [options.force]
   * @returns {Object}
   */
  closeSession(sessionId, options = {}) {
    const session = this.sessionsById.get(sessionId);
    if (!session) {
      throw createTerminalError("TERMINAL_SESSION_NOT_FOUND", `终端会话不存在: ${sessionId}`);
    }

    const reason = typeof options.reason === "string" && options.reason.trim().length > 0
      ? options.reason.trim()
      : "manual_close";
    const force = options.force === true;

    if (session.status === "running") {
      session.status = "closing";
      this.logger?.info?.(
        `[terminal] session closing: sessionId=${session.sessionId}, threadId=${session.threadId}, reason=${reason}`
      );
      session.pty.kill();
      if (!force) {
        return this.#toSessionSnapshot(session);
      }
    }

    this.#cleanupSession(session, reason);
    return this.#toSessionSnapshot(session);
  }

  #touchSession(session) {
    session.lastActiveAt = this.#nowIso();
  }

  #handleOutput(session, data) {
    if (session.status !== "running" && session.status !== "closing") {
      return;
    }
    const rawText = typeof data === "string" ? data : String(data ?? "");
    const text = this.#updateShellStateAndFilterOutput(session, rawText);
    if (!text) {
      this.#touchSession(session);
      return;
    }

    const frame = {
      type: "output",
      seq: session.nextSeq,
      data: text,
    };
    session.nextSeq += 1;
    session.outputFrames.push(frame);
    session.outputBytes += Buffer.byteLength(text, "utf8");

    while (session.outputBytes > this.maxScrollbackBytes && session.outputFrames.length > 0) {
      const removed = session.outputFrames.shift();
      if (!removed) {
        break;
      }
      session.outputBytes -= Buffer.byteLength(removed.data, "utf8");
    }

    this.#touchSession(session);
    this.#emitToListeners(session, frame);
  }

  #handleExit(session, result) {
    if (session.status === "exited") {
      return;
    }

    session.status = "exited";
    session.exitCode = Number.isInteger(result?.exitCode) ? result.exitCode : null;
    session.signal = result?.signal == null ? null : String(result.signal);
    session.foregroundBusy = false;
    session.backgroundJobs = 0;
    session.exitFrame = {
      type: "exit",
      seq: session.nextSeq,
      exitCode: session.exitCode,
      signal: session.signal,
    };
    this.#touchSession(session);
    this.#emitToListeners(session, session.exitFrame);
    this.sessionIdByThreadId.delete(session.threadId);
    this.logger?.info?.(
      `[terminal] session exited: sessionId=${session.sessionId}, threadId=${session.threadId}, exitCode=${session.exitCode}, signal=${session.signal ?? "null"}`
    );

    if (session.clients.size === 0) {
      this.#cleanupSession(session, "process_exit");
    }
  }

  #emitToListeners(session, payload) {
    for (const listener of session.listeners.values()) {
      try {
        listener(payload);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        this.logger?.warn?.(`[terminal] listener error: ${message}`);
      }
    }
  }

  /**
   * @param {any} session
   * @param {number|null|undefined} fromSeqRaw
   * @returns {Object[]}
   */
  #collectReplay(session, fromSeqRaw) {
    if (fromSeqRaw === null || fromSeqRaw === undefined) {
      return [];
    }

    const fromSeq = toFiniteInt(fromSeqRaw, Number.NaN, Number.MIN_SAFE_INTEGER);
    if (!Number.isInteger(fromSeq) || fromSeq < -1) {
      throw createTerminalError("TERMINAL_INVALID_INPUT", "fromSeq 必须是 >= -1 的整数");
    }

    if (session.outputFrames.length > 0) {
      const oldestSeq = session.outputFrames[0].seq;
      if (fromSeq < oldestSeq - 1) {
        throw createTerminalError("TERMINAL_CURSOR_EXPIRED", "cursor 已过期，请重新打开终端");
      }
    }

    const frames = session.outputFrames.filter((frame) => frame.seq > fromSeq);
    if (session.exitFrame && session.exitFrame.seq > fromSeq) {
      frames.push(session.exitFrame);
    }
    return frames;
  }

  async #sweepIdleSessions() {
    if (this.sweepRunning) {
      return;
    }
    this.sweepRunning = true;
    try {
      if (this.idleTtlMs <= 0) {
        return;
      }
      const now = this.now();
      const sessions = [...this.sessionsById.values()];
      for (const session of sessions) {
        if (session.clients.size > 0) {
          continue;
        }

        if (session.foregroundBusy || session.backgroundJobs > 0) {
          continue;
        }

        const idleMs = now - Date.parse(session.lastActiveAt);
        if (idleMs < this.idleTtlMs) {
          continue;
        }

        if (session.status === "running") {
          const hasChildren = await this.hasChildProcessChecker(session.pid);
          if (hasChildren) {
            continue;
          }
        }

        this.closeSession(session.sessionId, { reason: "idle_timeout", force: true });
      }
    } finally {
      this.sweepRunning = false;
    }
  }

  async #hasChildProcesses(parentPid) {
    try {
      const { stdout } = await execFile("pgrep", ["-P", String(parentPid)]);
      return stdout.trim().length > 0;
    } catch (error) {
      // pgrep exit code 1：没有子进程；其余错误保守处理为“有子进程”，避免误回收。
      if (typeof error === "object" && error && "code" in error) {
        if (error.code === 1) {
          return false;
        }
      }
      return true;
    }
  }

  #cleanupSession(session, reason) {
    this.sessionsById.delete(session.sessionId);
    this.sessionIdByThreadId.delete(session.threadId);
    session.listeners.clear();
    session.clients.clear();
    this.logger?.warn?.(
      `[terminal] session cleaned: sessionId=${session.sessionId}, threadId=${session.threadId}, reason=${reason}`
    );
  }

  #installShellStateHooks(session) {
    if (!this.trackShellState || session.status !== "running" || session.supportsShellStateHooks !== true) {
      return;
    }

    const script = `if [ -n "$ZSH_VERSION" ]; then autoload -Uz add-zsh-hook >/dev/null 2>&1; __cw_emit_state(){ local mode="$1"; local jobs_count; jobs_count=$(jobs -p | wc -l | tr -d ' '); print -r -- "${SHELL_STATE_MARKER}:$mode:$jobs_count"; }; __cw_preexec(){ __cw_emit_state busy; }; __cw_precmd(){ __cw_emit_state idle; }; add-zsh-hook preexec __cw_preexec >/dev/null 2>&1; add-zsh-hook precmd __cw_precmd >/dev/null 2>&1; __cw_emit_state idle; fi; print -r -- "${SHELL_BOOTSTRAP_DONE_MARKER}"\n`;
    try {
      session.pty.write(script);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.logger?.warn?.(
        `[terminal] failed to install shell state hooks: sessionId=${session.sessionId}, error=${message}`
      );
    }
  }

  #resolveFallbackShellArgs() {
    const shellName = path.basename(this.shell).toLowerCase();
    if (shellName.includes("zsh")) {
      // 回退模式下禁用用户自定义启动脚本，避免 compdef 等初始化报错。
      return ["-f"];
    }
    if (shellName.includes("bash")) {
      return ["--noprofile", "--norc"];
    }
    return [];
  }

  #resolvePrimaryPtyArgCandidates() {
    const shellName = path.basename(this.shell).toLowerCase();
    if (shellName.includes("zsh")) {
      // 先走 -f（稳定、无用户启动脚本副作用），必要时再退到 -i。
      return [["-f"], ["-i"], []];
    }
    if (shellName.includes("bash")) {
      return [["--noprofile", "--norc", "-i"], ["-i"], []];
    }
    return [["-i"], []];
  }

  #updateShellStateAndFilterOutput(session, text) {
    if (!this.trackShellState || !text) {
      return text;
    }

    const combined = `${session.shellStateCarry}${text}`;
    let processText = combined;
    let carry = "";
    const markerIndex = combined.lastIndexOf(`${SHELL_STATE_MARKER}:`);
    if (markerIndex >= 0) {
      const suffix = combined.slice(markerIndex);
      if (!suffix.includes("\n") && !suffix.includes("\r")) {
        processText = combined.slice(0, markerIndex);
        carry = suffix;
      }
    }
    session.shellStateCarry = carry;

    const markerRegex = /(?:\r?\n)?__CW_STATE__:(busy|idle):(\d+)(?:\r?\n)?/g;
    const stateFiltered = processText.replace(markerRegex, (_line, mode, jobsRaw) => {
      session.foregroundBusy = mode === "busy";
      const jobs = Number.parseInt(String(jobsRaw), 10);
      session.backgroundJobs = Number.isInteger(jobs) && jobs >= 0 ? jobs : 0;
      return "";
    });
    return this.#filterBootstrapNoise(session, stateFiltered);
  }

  #filterBootstrapNoise(session, text) {
    if (!session.suppressBootstrapNoise || !text) {
      return text;
    }

    const nowMs = this.now();
    if (nowMs - session.bootstrapStartedAtMs > BOOTSTRAP_SILENT_MAX_MS) {
      session.suppressBootstrapNoise = false;
      session.bootstrapFilterCarry = "";
      return text;
    }

    const combined = `${session.bootstrapFilterCarry}${text}`;
    const markerIndex = combined.indexOf(SHELL_BOOTSTRAP_DONE_MARKER);
    if (markerIndex < 0) {
      // 启动期仅做一次静默清屏：未看到完成标记前，暂不向客户端透传输出。
      session.bootstrapFilterCarry = combined.slice(-8192);
      return "";
    }

    session.suppressBootstrapNoise = false;
    session.bootstrapFilterCarry = "";

    const markerEnd = markerIndex + SHELL_BOOTSTRAP_DONE_MARKER.length;
    const remainder = combined.slice(markerEnd).replace(/^\r?\n/, "");
    return remainder;
  }

  #toSessionSnapshot(session) {
    return {
      sessionId: session.sessionId,
      threadId: session.threadId,
      cwd: session.cwd,
      shell: session.shell,
      pid: session.pid,
      status: session.status,
      createdAt: session.createdAt,
      lastActiveAt: session.lastActiveAt,
      cols: session.cols,
      rows: session.rows,
      exitCode: session.exitCode,
      signal: session.signal,
      nextSeq: session.nextSeq,
      clientCount: session.clients.size,
      transportMode: session.transportMode,
      foregroundBusy: session.foregroundBusy,
      backgroundJobs: session.backgroundJobs,
    };
  }

  #nowIso() {
    return new Date(this.now()).toISOString();
  }
}

/**
 * @param {Object} options
 * @returns {TerminalManager}
 */
export function createTerminalManager(options) {
  return new TerminalManager(options);
}
