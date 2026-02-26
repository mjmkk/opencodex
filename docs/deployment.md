# Deployment Guide / 部署指南

> Language / 语言：English below first, 中文在文末。

This guide covers self-hosting the OpenCodex backend (`codex-worker-mvp`).

## Prerequisites

- Node.js >= 22
- Access to a [Codex](https://codex.anthropic.com) `app-server` instance
- (Optional) [Tailscale](https://tailscale.com) for secure remote access

> **Note:** OpenCodex acts as a bridge between the iOS client and a Codex
> `app-server`. You need a valid Codex environment (API key + app-server)
> to use most features. The backend itself is open source; the Codex
> app-server is a separate service.

## Quick Start

```bash
cd codex-worker-mvp
npm install

# Copy and edit config
cp worker.config.example.json worker.config.json
```

Edit `worker.config.json`:

```json
{
  "port": 3000,
  "authToken": "your-secret-token",
  "codexBaseUrl": "http://localhost:3100",
  "tailscaleServiceName": "svc:opencodex"
}
```

Start the server:

```bash
npm start
```

## Configuration Reference

| Field | Required | Description |
|-------|----------|-------------|
| `port` | No (default: 3000) | HTTP port to listen on |
| `authToken` | Yes | Secret token; set the same value in the iOS app Settings |
| `codexBaseUrl` | Yes | Base URL of your Codex app-server |
| `tailscaleServiceName` | No | Tailscale Serve service name for remote access |
| `terminalEnabled` | No (default: true) | Enable/disable terminal feature |
| `pushNotifications` | No | APNs push notification config |

## Remote Access via Tailscale (Recommended)

Tailscale Serve makes the backend securely accessible from your iPhone
without port forwarding:

```bash
# Install Tailscale, then:
tailscale serve --bg http://localhost:3000
```

The iOS app should be configured with the Tailscale HTTPS URL
(e.g. `https://your-machine.tail12345.ts.net`).

## Running as a Service (macOS)

Create `~/Library/LaunchAgents/com.opencodex.worker.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.opencodex.worker</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/node</string>
    <string>/path/to/opencodex/codex-worker-mvp/src/index.js</string>
  </array>
  <key>WorkingDirectory</key>
  <string>/path/to/opencodex/codex-worker-mvp</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/opencodex-worker.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/opencodex-worker.err</string>
</dict>
</plist>
```

Load it:
```bash
launchctl load ~/Library/LaunchAgents/com.opencodex.worker.plist
```

## Health Check

```bash
curl -H "Authorization: Bearer your-secret-token" http://localhost:3000/v1/health
```

## Security Notes

- Never expose the backend directly to the internet without authentication
- Use Tailscale or a reverse proxy with TLS in production
- Keep `authToken` secret; rotate it if compromised (see `SECURITY.md`)
- Terminal feature gives shell access — only enable on trusted networks

---

## 中文速览

本文用于部署 `codex-worker-mvp` 后端服务。

### 前置条件

- Node.js >= 22
- 可访问的 Codex `app-server`
- 可选：Tailscale（用于远程安全访问）

### 快速启动

```bash
cd codex-worker-mvp
npm install
cp worker.config.example.json worker.config.json
```

编辑 `worker.config.json`（示例）：

```json
{
  "port": 3000,
  "authToken": "your-secret-token",
  "codexBaseUrl": "http://localhost:3100",
  "tailscaleServiceName": "svc:opencodex"
}
```

启动：

```bash
npm start
```

### 关键配置项

- `port`：监听端口，默认 `3000`
- `authToken`：鉴权令牌（需与 iOS 设置页一致）
- `codexBaseUrl`：Codex app-server 地址
- `tailscaleServiceName`：Tailscale Serve 服务名（可选）
- `terminalEnabled`：是否启用终端功能
- `pushNotifications`：推送配置

### 远程访问（推荐）

```bash
tailscale serve --bg http://localhost:3000
```

iOS 端使用 Tailscale HTTPS 地址（示例：`https://your-machine.tail12345.ts.net`）。

### 健康检查

```bash
curl -H "Authorization: Bearer your-secret-token" http://localhost:3000/v1/health
```

### 安全建议

- 不要在无鉴权情况下直接暴露到公网
- 生产环境请配合 TLS（或 Tailscale）
- `authToken` 泄露要立即轮换
- 终端功能具备 shell 权限，仅在可信网络启用
