# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenCodex is a system that enables iPhone to seamlessly continue Codex workflows started on Mac, with approval capabilities. The core component is `codex-worker-mvp`, a Mac Worker service that:

- Interfaces with OpenAI's official `codex app-server` via JSON-RPC 2.0 (stdio)
- Exposes REST + SSE APIs for mobile clients
- Supports approval requests (command execution and file changes)
- Persists events and approvals to SQLite for audit and replay

**Architecture:**
```
iPhone <--REST/SSE--> Worker (Node.js) <--JSON-RPC--> codex app-server
```

## Key Commands

```bash
# Start the worker
cd codex-worker-mvp && npm start

# Run unit tests
cd codex-worker-mvp && npm test

# Run all tests (unit + integration + smoke + scenario)
cd codex-worker-mvp && npm run test:all

# Run smoke test
cd codex-worker-mvp && npm run smoke

# Run scenario suite
cd codex-worker-mvp && npm run scenario
```

## Core Modules (codex-worker-mvp/src/)

| Module | Purpose |
|--------|---------|
| `json-rpc-client.js` | Spawn `codex app-server` subprocess, handle bidirectional JSON-RPC |
| `worker-service.js` | Business logic: thread/job state machine, approval handling |
| `sqlite-store.js` | SQLite persistence for threads, jobs, events, approvals |
| `http-server.js` | REST API server with SSE support |
| `config.js` | Environment variable parsing |

## Critical Protocol Details

### Parameter Naming (camelCase - matches official app-server)

- **approvalPolicy**: `suggest`, `auto`, `unlessTrusted`, `onFailure`, `onRequest`, `never`
- **sandbox**: `readOnly`, `workspaceWrite`, `dangerFullAccess`

Legacy kebab-case values are automatically converted for backward compatibility.

### Job State Machine

```
QUEUED -> RUNNING -> WAITING_APPROVAL (on approval.required)
                       |
                       v (on approval.resolved)
                     RUNNING -> DONE | FAILED | CANCELLED
```

Terminal states are determined by `turn/completed.status` (completed/failed/interrupted).

### Approval Idempotency

- Each `approvalId` can only be decided once
- Repeated `/approve` calls return the first decision
- Decision is persisted to SQLite for audit

### SSE Cursor Semantics

- Events have monotonically increasing `seq` within a job
- Client reconnects with `cursor` to resume from last seen event
- Heartbeat: `: ping` every 15 seconds

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | 8787 | HTTP port |
| `WORKER_TOKEN` | - | Bearer token for API auth |
| `WORKER_PROJECT_PATHS` | - | Comma-separated project path whitelist |
| `WORKER_DB_PATH` | `./data/worker.db` | SQLite database path |
| `CODEX_COMMAND` | `codex` | Path to codex binary |

## API Endpoints

Key endpoints for the Worker:

- `POST /v1/threads` - Create thread
- `POST /v1/threads/{id}/activate` - Resume thread
- `POST /v1/threads/{id}/turns` - Send message, create job
- `GET /v1/jobs/{id}/events?cursor=N` - SSE event stream
- `POST /v1/jobs/{id}/approve` - Submit approval decision
- `POST /v1/jobs/{id}/cancel` - Cancel running job

## Reference Documentation

- `mvp-architecture.md` - Full architecture specification
- `mvp-product-design.md` - Product requirements and UX design
- Official app-server protocol: `codex/codex-rs/app-server/README.md`
