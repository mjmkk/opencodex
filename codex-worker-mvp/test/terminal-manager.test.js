import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";

import { TerminalManager } from "../src/terminal-manager.js";

class FakePtyProcess {
  constructor(pid) {
    this.pid = pid;
    this.dataHandler = () => {};
    this.exitHandler = () => {};
    this.writes = [];
    this.resizeCalls = [];
    this.killed = false;
  }

  onData(handler) {
    this.dataHandler = handler;
  }

  onExit(handler) {
    this.exitHandler = handler;
  }

  write(data) {
    this.writes.push(data);
  }

  resize(cols, rows) {
    this.resizeCalls.push({ cols, rows });
  }

  kill() {
    this.killed = true;
    this.exitHandler({ exitCode: 0, signal: 0 });
  }

  emitData(data) {
    this.dataHandler(data);
  }
}

class FakePipeChild extends EventEmitter {
  constructor(pid = 5000) {
    super();
    this.pid = pid;
    this.killed = false;
    this.stdin = {
      destroyed: false,
      writes: [],
      write: (data) => {
        this.stdin.writes.push(data);
      },
    };
    this.stdout = new EventEmitter();
    this.stderr = new EventEmitter();
  }

  kill(signal) {
    this.killed = true;
    this.emit("exit", 0, signal ?? null);
  }
}

test("TerminalManager 基本流程：open/attach/replay/write/resize/close", () => {
  let pidSeed = 1000;
  const spawned = [];
  const manager = new TerminalManager({
    autoSweep: false,
    trackShellState: false,
    ptyAdapter: {
      spawn: () => {
        const process = new FakePtyProcess(pidSeed++);
        spawned.push(process);
        return process;
      },
    },
    logger: { warn: () => {} },
  });

  const opened = manager.openSession({
    threadId: "thr_1",
    cwd: "/repo",
    cols: 100,
    rows: 30,
  });
  assert.equal(opened.reused, false);
  assert.equal(opened.session.threadId, "thr_1");
  assert.equal(opened.session.cwd, "/repo");
  assert.equal(opened.session.status, "running");

  const attachedEvents = [];
  const attached = manager.attachClient({
    sessionId: opened.session.sessionId,
    clientId: "client_a",
    fromSeq: -1,
    onEvent: (event) => attachedEvents.push(event),
  });
  assert.equal(attached.replay.length, 0);

  spawned[0].emitData("hello");
  assert.equal(attachedEvents.length, 1);
  assert.equal(attachedEvents[0].type, "output");
  assert.equal(attachedEvents[0].data, "hello");

  const replay = manager.attachClient({
    sessionId: opened.session.sessionId,
    clientId: "client_b",
    fromSeq: -1,
    onEvent: () => {},
  });
  assert.equal(replay.replay.length, 1);
  assert.equal(replay.replay[0].data, "hello");

  manager.writeInput(opened.session.sessionId, "ls -la\n");
  assert.deepEqual(spawned[0].writes, ["ls -la\n"]);

  const resized = manager.resizeSession(opened.session.sessionId, 120, 40);
  assert.equal(resized.cols, 120);
  assert.equal(resized.rows, 40);
  assert.deepEqual(spawned[0].resizeCalls, [{ cols: 120, rows: 40 }]);

  manager.closeSession(opened.session.sessionId, { reason: "test_close" });
  assert.equal(spawned[0].killed, true);
  const exitedSession = manager.getSessionById(opened.session.sessionId);
  assert.equal(exitedSession?.status, "exited");
  manager.detachClient(opened.session.sessionId, "client_a");
  manager.detachClient(opened.session.sessionId, "client_b");
  assert.equal(manager.getSessionById(opened.session.sessionId), null);

  manager.shutdown();
});

test("TerminalManager 空闲回收不会误杀有子进程会话", async () => {
  let hasChildren = true;
  let now = Date.parse("2026-01-01T00:00:00.000Z");
  const manager = new TerminalManager({
    idleTtlMs: 25,
    autoSweep: false,
    trackShellState: false,
    now: () => now,
    hasChildProcessChecker: async () => hasChildren,
    ptyAdapter: {
      spawn: () => new FakePtyProcess(2000),
    },
    logger: { warn: () => {} },
  });

  const opened = manager.openSession({
    threadId: "thr_idle",
    cwd: "/repo",
  });

  manager.attachClient({
    sessionId: opened.session.sessionId,
    clientId: "client_idle",
    fromSeq: null,
    onEvent: () => {},
  });
  manager.detachClient(opened.session.sessionId, "client_idle");

  now += 30;
  await manager.sweepIdleSessionsOnce();
  assert.ok(manager.getSessionById(opened.session.sessionId), "有子进程时不应回收");

  hasChildren = false;
  now += 30;
  await manager.sweepIdleSessionsOnce();
  assert.equal(manager.getSessionById(opened.session.sessionId), null, "无子进程后应被回收");

  manager.shutdown();
});

test("TerminalManager 空闲回收遵循 shell 忙闲状态", async () => {
  let now = Date.parse("2026-01-01T00:00:00.000Z");
  const manager = new TerminalManager({
    idleTtlMs: 25,
    autoSweep: false,
    now: () => now,
    hasChildProcessChecker: async () => false,
    ptyAdapter: {
      spawn: () => new FakePtyProcess(3000),
    },
    logger: { warn: () => {} },
  });

  const opened = manager.openSession({
    threadId: "thr_busy_state",
    cwd: "/repo",
  });

  const session = manager.sessionsById.get(opened.session.sessionId);
  assert.ok(session);

  session.pty.emitData("__CW_STATE__:busy:0\r\n");
  manager.attachClient({
    sessionId: opened.session.sessionId,
    clientId: "client_busy_state",
    fromSeq: null,
    onEvent: () => {},
  });
  manager.detachClient(opened.session.sessionId, "client_busy_state");

  now += 30;
  await manager.sweepIdleSessionsOnce();
  assert.ok(manager.getSessionById(opened.session.sessionId), "前台忙时不应回收");

  session.pty.emitData("__CW_STATE__:idle:0\r\n");
  now += 30;
  await manager.sweepIdleSessionsOnce();
  assert.equal(manager.getSessionById(opened.session.sessionId), null, "空闲状态应可回收");

  manager.shutdown();
});

test("TerminalManager 在 node-pty spawn 失败时回退到 pipe 模式", () => {
  const fakeChild = new FakePipeChild(7777);
  const warnings = [];
  const spawnCalls = [];
  const manager = new TerminalManager({
    autoSweep: false,
    ptyAdapter: {
      spawn: () => {
        throw new Error("posix_spawnp failed.");
      },
    },
    childProcessSpawner: (shell, args) => {
      spawnCalls.push({ shell, args });
      return fakeChild;
    },
    logger: {
      warn: (message) => warnings.push(message),
      info: () => {},
    },
  });

  const opened = manager.openSession({
    threadId: "thr_pipe_fallback",
    cwd: "/repo",
  });

  assert.equal(opened.session.pid, 7777);
  assert.equal(opened.reused, false);
  assert.equal(opened.session.transportMode, "pipe");
  assert.equal(spawnCalls.length, 1);
  assert.deepEqual(spawnCalls[0].args, ["-f"]);
  assert.ok(warnings.some((message) => String(message).includes("fallback to pipe mode")));

  manager.writeInput(opened.session.sessionId, "pwd\n");
  assert.ok(fakeChild.stdin.writes.some((item) => item === "pwd\n"));

  const events = [];
  manager.attachClient({
    sessionId: opened.session.sessionId,
    clientId: "client_pipe",
    fromSeq: -1,
    onEvent: (event) => events.push(event),
  });

  fakeChild.stdout.emit("data", Buffer.from("hello from stdout\n"));
  fakeChild.stderr.emit("data", Buffer.from("hello from stderr\n"));
  assert.ok(events.some((event) => event.type === "output" && event.data.includes("stdout")));
  assert.ok(events.some((event) => event.type === "output" && event.data.includes("stderr")));

  manager.closeSession(opened.session.sessionId, { reason: "test_pipe_close" });
  manager.detachClient(opened.session.sessionId, "client_pipe");
  assert.equal(manager.getSessionById(opened.session.sessionId), null);
});

test("TerminalManager 在 zsh -f 失败时会改用 zsh -i 并保持 PTY 模式", () => {
  const ptyCalls = [];
  const warnings = [];
  const fallbackCalls = [];
  const manager = new TerminalManager({
    autoSweep: false,
    ptyAdapter: {
      spawn: (_shell, args) => {
        ptyCalls.push(args);
        if (args.length === 1 && args[0] === "-f") {
          throw new Error("posix_spawnp failed.");
        }
        return new FakePtyProcess(8888);
      },
    },
    childProcessSpawner: (...args) => {
      fallbackCalls.push(args);
      throw new Error("should not fallback to pipe");
    },
    logger: {
      warn: (message) => warnings.push(String(message)),
      info: () => {},
    },
  });

  const opened = manager.openSession({
    threadId: "thr_pty_retry",
    cwd: "/repo",
  });

  assert.equal(opened.session.transportMode, "pty");
  assert.equal(opened.session.pid, 8888);
  assert.deepEqual(ptyCalls, [["-f"], ["-i"]]);
  assert.equal(fallbackCalls.length, 0);
  assert.ok(warnings.some((message) => message.includes("recovered with alternate args")));
});

test("TerminalManager 仍会过滤 __CW_STATE__ 标记并更新忙闲状态", () => {
  const process = new FakePtyProcess(10001);
  const events = [];
  const manager = new TerminalManager({
    autoSweep: false,
    ptyAdapter: {
      spawn: () => process,
    },
    logger: {
      warn: () => {},
      info: () => {},
    },
  });

  const opened = manager.openSession({
    threadId: "thr_bootstrap_timeout",
    cwd: "/repo",
  });

  manager.attachClient({
    sessionId: opened.session.sessionId,
    clientId: "client_state_markers",
    fromSeq: -1,
    onEvent: (event) => events.push(event),
  });

  process.emitData("__CW_STATE__:busy:1\r\nhello from shell\r\n__CW_STATE__:idle:0\r\n");
  const payload = events.map((event) => String(event.data ?? "")).join("");
  assert.ok(payload.includes("hello from shell"));
  assert.ok(!payload.includes("__CW_STATE__"));

  const snapshot = manager.getSessionById(opened.session.sessionId);
  assert.equal(snapshot?.foregroundBusy, false);
  assert.equal(snapshot?.backgroundJobs, 0);
});
