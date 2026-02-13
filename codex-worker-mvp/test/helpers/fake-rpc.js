import { EventEmitter } from "node:events";

export class FakeRpcClient extends EventEmitter {
  constructor() {
    super();
    this.started = false;
    this.notifications = [];
    this.responses = [];
    this.requestHandlers = new Map();
  }

  async start() {
    this.started = true;
  }

  async stop() {
    this.started = false;
  }

  onRequest(method, handler) {
    this.requestHandlers.set(method, handler);
  }

  async request(method, params) {
    const handler = this.requestHandlers.get(method);
    if (!handler) {
      throw new Error(`no fake handler for request: ${method}`);
    }
    return handler(params);
  }

  notify(method, params) {
    this.notifications.push({ method, params });
  }

  respond(id, result) {
    this.responses.push({ id, result });
  }

  respondError(id, code, message, data = undefined) {
    this.responses.push({ id, error: { code, message, data } });
  }
}
