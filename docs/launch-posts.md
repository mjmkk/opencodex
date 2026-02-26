# OpenCodex 推广发帖文案

> 直接复制粘贴即可发布，每个平台都针对受众做了优化。

---

## 1. Hacker News — Show HN

**标题（< 80 字符）：**
```
Show HN: OpenCodex – Run Claude/Codex AI from your iPhone with a real terminal
```

**正文：**
```
I built OpenCodex – a native iOS app + self-hosted Node.js backend that lets you 
control Claude / Codex from your iPhone.

What makes it different from other AI chat apps:
- Full PTY terminal over WebSocket (resize, ANSI colors, real shell)
- Command approval flow – dangerous commands pause and wait for your tap
- File browser with full-text search and in-app editing
- Tap path:line references in AI messages to jump directly to the file
- Everything is self-hosted – no cloud relay, data stays on your Mac

Tech stack: Swift 6 + SwiftUI + TCA on iOS, Node.js 22 + better-sqlite3 + node-pty on backend.

The use case: I run Codex/Claude on my Mac to handle long-running coding tasks, 
and wanted to monitor and steer them from my phone without opening my laptop.

Getting started takes ~3 commands with Docker.

GitHub: https://github.com/mjmkk/opencodex
```

**最佳发帖时间：** 周一/二 上午 9-11 点（美东时间）  
**发帖地址：** https://news.ycombinator.com/submit

---

## 2. Reddit — r/LocalLLaMA

**标题：**
```
I built a native iPhone app to control Claude/Codex with a real terminal – OpenCodex (self-hosted, Apache 2.0)
```

**正文：**
```
Hey r/LocalLLaMA,

I've been building OpenCodex – a native iOS app that lets you run Claude/Codex AI 
from your iPhone, with a proper terminal and command approval flow.

**Why I built it:** I use Codex for long-running coding tasks on my Mac. 
I wanted to monitor and steer these sessions from my phone (approve/reject commands, 
browse files, check what the AI is doing) without opening my laptop.

**What it does:**
- 💬 Real-time AI chat with SSE streaming
- 🖥️ Full PTY terminal over WebSocket (resize, colors, real /bin/sh)
- 📁 File browser with search and editing
- ✅ Command approval – AI pauses before running dangerous commands
- 🔗 Tap `src/auth.js:42` in a message → opens that file

**Architecture:**
iPhone App (Swift/TCA) ↔ Worker (Node.js) ↔ codex app-server (local Mac)

No cloud relay. Everything runs locally.

**Self-hosted:** Docker Compose in 3 commands, or run the Node.js server directly.

GitHub: https://github.com/mjmkk/opencodex

Happy to answer questions about the architecture or the PTY/WebSocket terminal implementation.
```

**发帖地址：** https://www.reddit.com/r/LocalLLaMA/submit

---

## 3. Reddit — r/iOSProgramming

**标题：**
```
Built a native iOS app (Swift 6 + TCA) that controls an AI coding assistant with a real WebSocket terminal
```

**正文：**
```
Hey r/iOSProgramming!

I wanted to share OpenCodex – a native iOS app I built to control Claude/Codex AI 
from my iPhone.

**Technical highlights for iOS devs:**

1. **TCA (Composable Architecture)** – full feature module isolation, testable reducers for chat, terminal, file browser, and approval flows

2. **WebSocket PTY terminal** – using SwiftTerm for ANSI rendering, with frame sequence numbers for reliable reconnect and incremental replay

3. **SSE streaming** – cursor-based event stream with automatic recovery on foreground resume (solves the classic "app backgrounded mid-stream" problem)

4. **Swift 6 strict concurrency** – fully actor-isolated, no data races

5. **File browser** – tree view with full-text search, tap path:line references in AI messages to jump to that file

It's all open source (Apache 2.0):
https://github.com/mjmkk/opencodex

I'd love feedback on the TCA architecture choices especially – the terminal feature has some interesting state management challenges.
```

**发帖地址：** https://www.reddit.com/r/iOSProgramming/submit

---

## 4. Reddit — r/selfhosted

**标题：**
```
OpenCodex – self-hosted iOS client to run Claude/Codex AI with terminal access (Docker Compose, Apache 2.0)
```

**正文：**
```
Hi r/selfhosted,

I've been running Codex/Claude on my Mac for coding tasks, and built a self-hosted 
solution to control it from my iPhone: OpenCodex.

**Self-hosting setup:**
```bash
git clone https://github.com/mjmkk/opencodex
cp codex-worker-mvp/worker.config.example.json codex-worker-mvp/worker.config.json
make docker-up  # starts the Node.js worker in Docker
```
Then build the iOS app in Xcode (or wait for TestFlight).

**What you get:**
- iPhone app that connects to your local Mac worker
- Real terminal (PTY) over WebSocket – full shell access
- Command approval – AI asks before running dangerous commands
- File browser for your project files
- Everything on your local network, nothing goes to the cloud

Worker is Node.js 22, uses SQLite for persistence, Docker image is alpine-based (~small).

https://github.com/mjmkk/opencodex
```

**发帖地址：** https://www.reddit.com/r/selfhosted/submit

---

## 5. Twitter/X 推文串

**推文 1（主推文）：**
```
I built OpenCodex – control Claude/Codex AI from your iPhone 📱

• Real PTY terminal over WebSocket
• Command approval (AI pauses before running risky commands)
• File browser with tap-to-open path:line references
• 100% self-hosted, nothing leaves your Mac

github.com/mjmkk/opencodex

🧵 Thread on how it works:
```

**推文 2：**
```
The architecture: 

iPhone App (Swift/SwiftUI/TCA)
    ↕ REST + SSE + WebSocket
Node.js Worker (your Mac)
    ↕ JSON-RPC stdio
codex app-server (local process)

No cloud relay. Your code stays on your machine.
```

**推文 3：**
```
The hardest part was the terminal implementation.

WebSocket PTY with:
→ Frame sequence numbers (detect lost frames on reconnect)
→ Incremental replay (re-stream only what you missed)
→ Heartbeat timeout (detect zombie connections)
→ SwiftTerm for proper ANSI rendering on iOS
```

**推文 4：**
```
Command approval was the killer feature for me.

When Codex wants to run `rm -rf ./old-auth`, it pauses and shows a sheet on your phone.

You can: ✅ Approve / ❌ Reject / ✏️ Modify

Then it continues. Full control from your couch.
```

**推文 5：**
```
Open source, Apache 2.0.

Self-host in 3 commands:
git clone github.com/mjmkk/opencodex
cp worker.config.example.json worker.config.json
make docker-up

iOS app via Xcode (TestFlight coming soon).

⭐ Star if useful: github.com/mjmkk/opencodex
```

---

## 6. dev.to 文章标题 + 摘要

**标题：**
```
Building a Native iOS Terminal for Claude/Codex AI — Architecture Deep Dive
```

**副标题 / 摘要：**
```
How I built OpenCodex: a Swift 6 + TCA iOS app with a real PTY terminal over 
WebSocket, SSE streaming with auto-reconnect, and a command approval flow — 
all backed by a self-hosted Node.js server.
```

**标签：** `swift`, `ios`, `ai`, `opensource`

**发文地址：** https://dev.to/new

---

## 7. Product Hunt（等功能稳定后）

**Tagline（< 60 字符）：**
```
Control Claude/Codex AI from your iPhone — with a real terminal
```

**Description：**
```
OpenCodex is a native iOS app + self-hosted Node.js backend that lets you run 
Claude / Codex AI coding sessions from your iPhone.

Unlike other AI chat apps, OpenCodex gives you a full PTY terminal over WebSocket, 
a file browser, and a command approval flow — so you can supervise AI coding tasks 
from anywhere, without opening your laptop.

Self-hosted. Open source. Apache 2.0.
```

---

*文案生成时间：2026-02-26*
