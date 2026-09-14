# Mobile sync and approval candidate

This extends the existing SwiftUI/TCA client and SQLite Worker. Shared native mode observes an explicit list of existing threads. Reading, reconnecting and restoring a cache do not create threads or start model turns.

## Native Worker setup

Use Node.js 22 or newer, run `npm ci` in `codex-worker-mvp`, and supply a private configuration file. Keep the Worker on loopback behind an authenticated HTTPS endpoint. The example paths and identifiers below must be replaced with an existing native socket and authorized thread registrations.

```json
{
  "host": "127.0.0.1",
  "port": 8789,
  "dbPath": "/srv/opencodex/state/worker.db",
  "projectPaths": ["/srv/project"],
  "defaultProjectPath": "/srv/project",
  "rpc": {
    "transport": "unix",
    "socketPath": "/run/user/1000/codex/app-server.sock",
    "observedThreadIds": ["EXISTING_THREAD_ID"]
  },
  "terminal": { "enabled": false },
  "tailscaleServe": { "enabled": false }
}
```

Set `WORKER_TOKEN` securely outside the repository, then run `node src/index.js --config /path/to/private-config.json`. Shared native mode requires authentication and refuses to mirror unregistered threads. A `websocket-proxy` transport can instead use `rpc.command` and `rpc.args` for an existing official app-server proxy. Its WebSocket handshake disables compression for compatibility with the native proxy. Use a service supervisor to restart this reader after transport failure; it reconnects and reconciles the same thread IDs.

Shared native mode preserves the original thread's permissions and model. It disables thread creation/archive, direct file writes and permission overrides. Sending ordinary chat or answering a supported native command/file approval requires a configured `mobileApprovals` bridge with a successful `validate_thread` operation. Unsupported native MCP, permission or user-input requests remain in the original Codex review UI.

## Durable data and APIs

`ThreadSyncLog` commits events to SQLite before live hints are emitted. A generation plus ordered cursor supports deduplication and recovery. iOS stores threads, activity, checkpoints, unread/Pin metadata, approvals and approval drafts in its existing GRDB database, isolated by endpoint/account. It reads cached content first, then fills gaps independently of the selected page.

| API | Purpose |
| --- | --- |
| `GET /v1/threads` | Authorized native thread catalog |
| `GET /v1/threads/:id/events` | Bounded durable event pages; generation/cursor recovery |
| `GET /v1/threads/:id/events/:cursor/detail` | Generation-checked full payload in chunks |
| `GET /v1/sync/stream` | Coalesced SSE hints; clients still read durable truth |
| `GET /v1/approvals` | Structured requests through the configured adapter |
| `POST /v1/approvals/:id/answer` | Versioned single response |
| `POST /v1/approvals/batch` | Explicitly scoped batch responses |
| `GET /v1/mobile/audit` | HTTP bytes/requests, push attempts and approval costs |

Large event payloads use previews in normal pages and fetch original content on demand. A failed/cancelled generation rebuild keeps the prior visible cache. Server-disconnected reads do not advance the client's freshness timestamp. Full detail chunks currently require a network connection; preview content remains available offline. Durable event retention is not yet bounded by the legacy in-memory `eventRetention` setting; budget disk storage accordingly.

## Structured approval adapter

`mobileApprovals` accepts a fixed server-configured executable and argument array. The bridge sends one JSON object `{ "operation": "...", "body": {} }` on stdin and reads one JSON result on stdout. Client data cannot choose the executable. Operations are `list`, `get`, `view`, `audit`, `answer`, `batch`, and `validate_thread`.

The Spirit adapter lives in `spirit-agent/mobile_approvals.py`. Its private configuration supplies the existing approval/input databases, endpoint configuration, Primary bindings, a protected Linear key file, and a registered thread-to-Issue map. Both submission and queue delivery validate the current Issue context, original Primary, request version, expiration and task state. The immutable response event ID reconciles the approval database with the existing input queue after a crash. An uncertain write is never automatically retried with a new ID.

The Inbox supports approve/reject, single/multiple choices, text and nested forms. Batch submission requires one explicit ordinary-risk scope, current context, target and matching request versions. Drafts are persistent, but offline content does not imply approval or execution. Current notification actions open the Inbox for contextual review; direct notification-only approval submission is not implemented.

## Notifications and iOS targets

The Xcode project includes the main app, a light Notification Service Extension, a Live Activity widget extension and a test target. Configure a valid signing team and profiles for all three app bundles. Set APNs credentials using protected `apns.keyPath`, `teamId`, `keyId`, `bundleId`, and the matching sandbox/production environment. Never commit the private key or device token.

The dependency-free `codex-activity-models` package shares Live Activity attributes between the app and widget. Keeping it separate preserves the existing `CodexWorker` package test scheme used by CI.

Progress hints are silent and limited to three attempts per hour per device. Completion notifications are coalesced by thread. Approval IDs and versions remain independent. Payloads contain identifiers and generic readable fallback text, not commands, full logs or credentials. APNs acceptance, device delivery and human visibility are separate metrics; unknown delivery/visibility/energy/billing stay unknown.

Foreground SSE, bounded background refresh and silent push opportunities fill cache gaps. iOS does not guarantee background execution or push delivery. Live Activities begin only after an explicit Pin, end on Unpin or task completion, and never grant execution permissions. Activity updates currently depend on local foreground/background opportunities; remote Live Activity push updates are not implemented.

## Validation

Run `npm test` in `codex-worker-mvp`. Build/test the shared `CodexWorkerApp` Xcode scheme against an installed iOS simulator using the tracked package resolution. Keep simulator results separate from real-device evidence.

The candidate has exercised durable paging and large-content reconstruction, generation recovery, account isolation, offline drafts, native permission/connection guards, push policy/JWT serialization and cold-cache freshness. Deployment verification additionally used a real native backend and simulator chat round-trip, offline cold launch, expired request, Pin/Unpin and reader restart without starting existing tasks again.

Real iPhone signing, APNs delivery, normal domestic API connectivity and approval-to-original-task execution still require device/environment acceptance. A build or an APNs HTTP response is not that acceptance.
