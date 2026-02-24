import test from "node:test";
import assert from "node:assert/strict";

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
