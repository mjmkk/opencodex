/**
 * Codex Worker MVP - 前端聊天界面
 * 
 * 设计原则：
 * 1. 单一数据源：所有消息显示由 SSE 事件驱动，用 itemId 去重
 * 2. sendMessage() 只负责发送请求，不直接显示消息
 * 3. 用户发送消息后显示"发送中..."临时状态，SSE 确认后正式显示
 * 
 * 重构说明：
 * - 提取 SVG 常量避免重复
 * - 统一消息渲染逻辑
 * - 修复业务逻辑问题
 * - 添加详细中文注释
 */

// ===== SVG 图标常量 =====
// 提取为常量，避免代码中重复定义
// 注意：threadIcon 已经包含 class="thread-icon"
const SVG_ICONS = {
  // 用户头像
  userAvatar: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>',
  
  // Codex/AI 头像（三层叠加图标）
  codexAvatar: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2L2 7l10 5 10-5-10-5z"/><path d="M2 17l10 5 10-5"/><path d="M2 12l10 5 10-5"/></svg>',
  
  // 线程列表图标（已包含正确的 class）
  threadIcon: '<svg class="thread-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>',
};

// ===== 状态管理 =====
// 集中管理所有应用状态，便于追踪和调试
const state = {
  activeThreadId: null,       // 当前激活的线程 ID
  activeJobId: null,          // 当前执行的任务 ID
  activeJobState: null,       // 当前任务状态（QUEUED/RUNNING/WAITING_APPROVAL/DONE/FAILED/CANCELLED）
  cursor: -1,                 // SSE 事件游标，用于断点续传
  sseAbort: null,             // SSE 中止控制器，用于取消 SSE 连接
  activeApproval: null,       // 当前待审批的请求 { approvalId, kind }
  messages: [],               // 消息历史记录（用于本地存储和显示）
  threads: [],                // 线程列表
  currentAssistantMsg: null,  // 当前正在构建的 AI 消息 DOM 元素引用（用于增量更新）
  displayedItemIds: new Set(), // 已显示的消息 ID（用于去重，防止重复显示）
  isSending: false,           // 是否正在发送消息（防止重复发送）
  lastActivityTime: 0,        // 最后活动时间，用于 SSE 心跳检测
  isLoadingHistory: false,    // 是否正在从 resume 加载历史（用于显示加载状态）
};

// ===== DOM 元素获取工具 =====
// 封装 getElementById，添加错误提示
const $ = (id) => {
  const el = document.getElementById(id);
  if (!el) {
    console.error(`DOM 元素未找到: #${id}`);
    throw new Error(`Element not found: #${id}`);
  }
  return el;
};

// ===== DOM 引用（按功能分组）=====
const dom = {
  // 侧边栏相关
  sidebar: $("sidebar"),
  sidebarToggle: $("sidebarToggle"),
  newThreadBtn: $("newThreadBtn"),
  refreshThreads: $("refreshThreads"),
  threadsList: $("threadsList"),
  settingsBtn: $("settingsBtn"),
  
  // 主聊天区域
  mobileMenuBtn: $("mobileMenuBtn"),
  statusBadge: $("statusBadge"),
  autoApprove: $("autoApprove"),
  toggleLog: $("toggleLog"),
  messagesContainer: $("messagesContainer"),
  messages: $("messages"),
  messageInput: $("messageInput"),
  sendBtn: $("sendBtn"),
  stopBtn: $("stopBtn"),
  activeThreadName: $("activeThreadName"),
  cursorInfo: $("cursorInfo"),
  
  // 日志面板
  logPanel: $("logPanel"),
  copyLog: $("copyLog"),
  clearLog: $("clearLog"),
  closeLog: $("closeLog"),
  logContent: $("logContent"),
  
  // 新建对话弹窗
  newThreadModal: $("newThreadModal"),
  closeNewThreadModal: $("closeNewThreadModal"),
  projectPath: $("projectPath"),
  threadName: $("threadName"),
  approvalPolicy: $("approvalPolicy"),
  sandboxMode: $("sandboxMode"),
  cancelNewThread: $("cancelNewThread"),
  createThread: $("createThread"),
  
  // 设置弹窗
  settingsModal: $("settingsModal"),
  closeSettingsModal: $("closeSettingsModal"),
  baseUrl: $("baseUrl"),
  token: $("token"),
  turnApprovalPolicy: $("turnApprovalPolicy"),
  saveSettings: $("saveSettings"),
  
  // 审批弹窗
  approvalModal: $("approvalModal"),
  apprKind: $("apprKind"),
  apprCmd: $("apprCmd"),
  apprCwd: $("apprCwd"),
  apprReason: $("apprReason"),
  apprAccept: $("apprAccept"),
  apprDecline: $("apprDecline"),
  apprCancel: $("apprCancel"),
};

// ===== 配置常量 =====
const CONFIG = {
  SSE_HEARTBEAT_TIMEOUT: 60000,  // SSE 心跳超时时间（60秒无活动则重连）
  SSE_RETRY_DELAY: 1000,         // SSE 重连延迟
  API_TIMEOUT: 30000,            // API 请求超时时间
  INPUT_MAX_HEIGHT: 200,         // 输入框最大高度
  TOAST_DURATION: 3000,          // Toast 提示显示时长
};

// ===== 本地存储工具 =====
// 封装 localStorage，添加异常处理
const storage = {
  get: (key, fallback = "") => {
    try {
      const v = localStorage.getItem(key);
      return v === null ? fallback : v;
    } catch {
      // localStorage 可能被禁用（如隐私模式）
      return fallback;
    }
  },
  set: (key, value) => {
    try {
      localStorage.setItem(key, value);
    } catch { /* 忽略存储错误 */ }
  },
  getBool: (key, fallback = false) => storage.get(key, fallback ? "1" : "0") === "1",
  setBool: (key, value) => storage.set(key, value ? "1" : "0"),
};

// ===== 工具函数 =====
const utils = {
  /** 获取当前 ISO 时间字符串 */
  now: () => new Date().toISOString(),
  
  /** 格式化时间为本地时间（时:分） */
  formatTime: (iso) => {
    const d = new Date(iso);
    return d.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" });
  },
  
  /** 截断字符串，添加省略号 */
  truncate: (str, len = 30) => {
    if (!str) return "";
    return str.length > len ? str.slice(0, len) + "..." : str;
  },
  
  /** HTML 转义，防止 XSS 攻击 */
  escapeHtml: (text) => {
    const div = document.createElement("div");
    div.textContent = text;
    return div.innerHTML;
  },
  
  /** 规范化 baseUrl，移除末尾斜杠 */
  normalizeBaseUrl: (value) => {
    const v = String(value || "").trim();
    if (!v) return "";
    return v.endsWith("/") ? v.slice(0, -1) : v;
  },
  
  /** 滚动消息容器到底部 */
  scrollToBottom: () => {
    dom.messagesContainer.scrollTop = dom.messagesContainer.scrollHeight;
  },
  
  /** 延迟执行（Promise 包装） */
  sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
  
  /** 带超时的 fetch */
  fetchWithTimeout: async (url, options = {}, timeout = CONFIG.API_TIMEOUT) => {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), timeout);
    
    try {
      const res = await fetch(url, {
        ...options,
        signal: controller.signal,
      });
      clearTimeout(timeoutId);
      return res;
    } catch (e) {
      clearTimeout(timeoutId);
      if (e.name === "AbortError") {
        throw new Error("请求超时，请检查网络连接");
      }
      throw e;
    }
  },
};

// ===== Toast 提示（替代 alert）=====
const toast = {
  /** 显示 Toast 提示 */
  show: (message, type = "info") => {
    // 移除已有的 toast
    const existing = document.querySelector(".toast");
    if (existing) existing.remove();
    
    const el = document.createElement("div");
    el.className = `toast toast-${type}`;
    el.textContent = message;
    document.body.appendChild(el);
    
    // 添加样式（如果还没有）
    if (!document.querySelector("#toast-styles")) {
      const style = document.createElement("style");
      style.id = "toast-styles";
      style.textContent = `
        .toast {
          position: fixed;
          bottom: 80px;
          left: 50%;
          transform: translateX(-50%);
          padding: 12px 24px;
          border-radius: 8px;
          font-size: 14px;
          z-index: 9999;
          animation: toastIn 0.3s ease;
        }
        .toast-info { background: #3b82f6; color: white; }
        .toast-error { background: #ef4444; color: white; }
        .toast-success { background: #10a37f; color: white; }
        @keyframes toastIn {
          from { opacity: 0; transform: translateX(-50%) translateY(20px); }
          to { opacity: 1; transform: translateX(-50%) translateY(0); }
        }
      `;
      document.head.appendChild(style);
    }
    
    setTimeout(() => el.remove(), CONFIG.TOAST_DURATION);
  },
  
  error: (msg) => toast.show(msg, "error"),
  success: (msg) => toast.show(msg, "success"),
  info: (msg) => toast.show(msg, "info"),
};

// ===== 日志管理 =====
const log = {
  /** 添加日志行 */
  append: (line) => {
    dom.logContent.textContent += `[${utils.now()}] ${line}\n`;
    dom.logContent.scrollTop = dom.logContent.scrollHeight;
  },
  /** 清空日志 */
  clear: () => {
    dom.logContent.textContent = "";
  },
};

// ===== API 封装 =====
const api = {
  /** 构建请求头（包含认证信息）*/
  headers: () => {
    const token = String(dom.token.value || "").trim();
    const headers = { "Content-Type": "application/json" };
    if (token) headers.Authorization = `Bearer ${token}`;
    return headers;
  },
  
  /** 统一的 fetch 封装，处理错误和 JSON 解析 */
  fetch: async (path, init = {}) => {
    const baseUrl = utils.normalizeBaseUrl(dom.baseUrl.value);
    if (!baseUrl) throw new Error("请先配置 Worker 地址");
    
    const url = `${baseUrl}${path}`;
    const res = await utils.fetchWithTimeout(url, {
      ...init,
      headers: { ...api.headers(), ...init.headers },
    });
    
    // 解析响应
    const text = await res.text();
    let json = null;
    if (text.trim()) {
      try {
        json = JSON.parse(text);
      } catch {
        throw new Error(`HTTP ${res.status} 返回非 JSON: ${text.slice(0, 200)}`);
      }
    }
    
    // 检查 HTTP 状态
    if (!res.ok) {
      const msg = json?.error?.message || JSON.stringify(json) || text || "Unknown error";
      throw new Error(`HTTP ${res.status} ${path}: ${msg}`);
    }
    
    return json;
  },
  
  /** 健康检查（不需要认证）*/
  getHealth: async () => {
    const baseUrl = utils.normalizeBaseUrl(dom.baseUrl.value);
    if (!baseUrl) return null;
    try {
      const res = await utils.fetchWithTimeout(`${baseUrl}/health`, {}, 5000);
      return res.json();
    } catch {
      return null;
    }
  },
  
  /** 获取项目列表 */
  getProjects: async () => {
    const data = await api.fetch("/v1/projects");
    return Array.isArray(data?.data) ? data.data : [];
  },
  
  /** 获取线程列表 */
  getThreads: async () => {
    const data = await api.fetch("/v1/threads");
    return Array.isArray(data?.data) ? data.data : [];
  },
  
  /** 创建新线程 */
  createThread: async (payload) => {
    return api.fetch("/v1/threads", { method: "POST", body: JSON.stringify(payload) });
  },
  
  /** 激活线程（恢复会话状态）*/
  activateThread: async (threadId) => {
    return api.fetch(`/v1/threads/${encodeURIComponent(threadId)}/activate`, {
      method: "POST",
      body: JSON.stringify({}),
    });
  },
  
  /** 获取线程历史事件 */
  getThreadEvents: async (threadId) => {
    const data = await api.fetch(`/v1/threads/${encodeURIComponent(threadId)}/events`);
    return Array.isArray(data?.data) ? data.data : [];
  },
  
  /** 创建新的对话轮次 */
  createTurn: async (threadId, payload) => {
    return api.fetch(`/v1/threads/${encodeURIComponent(threadId)}/turns`, {
      method: "POST",
      body: JSON.stringify(payload),
    });
  },
  
  /** 取消任务 */
  cancelJob: async (jobId) => {
    return api.fetch(`/v1/jobs/${encodeURIComponent(jobId)}/cancel`, {
      method: "POST",
      body: JSON.stringify({}),
    });
  },
  
  /** 提交审批决定 */
  approveJob: async (jobId, approvalId, decision) => {
    return api.fetch(`/v1/jobs/${encodeURIComponent(jobId)}/approve`, {
      method: "POST",
      body: JSON.stringify({ approvalId, decision }),
    });
  },
};

// ===== SSE 事件流处理 =====
const sse = {
  /**
   * 解析 SSE 数据格式
   * SSE 格式：每个事件以 "data:" 开头，事件之间用空行分隔
   * 
   * @param {string} buffer - 待解析的缓冲区数据
   * @returns {{ events: Array, rest: string }} - 解析出的事件数组和剩余未完成的缓冲区
   */
  parse: (buffer) => {
    const events = [];
    const parts = buffer.split("\n\n");
    const rest = parts.pop() ?? "";  // 最后一个可能是未完成的
    
    for (const raw of parts) {
      const lines = raw.split("\n");
      const dataLines = [];
      for (const line of lines) {
        if (line.startsWith("data:")) {
          dataLines.push(line.slice("data:".length).trim());
        }
        // 忽略注释行（如 ": ping" 心跳）
      }
      if (dataLines.length === 0) continue;
      try {
        events.push(JSON.parse(dataLines.join("\n")));
      } catch { /* 忽略 JSON 解析错误 */ }
    }
    
    return { events, rest };
  },
  
  /**
   * 启动 SSE 连接
   * 
   * 关键设计：
   * 1. 使用心跳检测而非固定超时，避免长时间任务中断
   * 2. 支持 AbortController 取消
   * 3. 自动重连，带指数退避
   * 
   * @param {string} jobId - 任务 ID
   */
  start: async (jobId) => {
    // 先停止旧的 SSE 连接
    if (state.sseAbort) state.sseAbort.abort();
    state.sseAbort = new AbortController();
    const signal = state.sseAbort.signal;
    
    log.append(`sse.start jobId=${jobId}`);
    ui.setStatus("running", "执行中");
    state.lastActivityTime = Date.now();
    
    while (!signal.aborted) {
      try {
        const baseUrl = utils.normalizeBaseUrl(dom.baseUrl.value);
        const url = `${baseUrl}/v1/jobs/${encodeURIComponent(jobId)}/events?cursor=${state.cursor}`;
        
        const res = await fetch(url, {
          headers: {
            Accept: "text/event-stream",
            Authorization: dom.token.value ? `Bearer ${dom.token.value}` : "",
          },
          signal,
        });
        
        if (!res.ok || !res.body) throw new Error(`events HTTP ${res.status}`);
        
        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buf = "";
        
        // 使用心跳检测，而非固定超时
        // 只要 60 秒内有活动（收到数据或心跳），就保持连接
        while (!signal.aborted) {
          // 检查心跳超时
          const idleTime = Date.now() - state.lastActivityTime;
          if (idleTime > CONFIG.SSE_HEARTBEAT_TIMEOUT) {
            log.append(`sse.heartbeat_timeout ${idleTime}ms`);
            break;  // 超时，退出内层循环进行重连
          }
          
          // 设置读取超时（用于检查心跳）
          const readPromise = reader.read();
          const timeoutPromise = new Promise((_, reject) => {
            setTimeout(() => reject(new Error("read_timeout")), 5000);
          });
          
          let value, done;
          try {
            const result = await Promise.race([readPromise, timeoutPromise]);
            value = result.value;
            done = result.done;
          } catch (e) {
            // 读取超时，继续循环检查心跳
            continue;
          }
          
          if (done) break;
          
          // 收到数据，更新活动时间
          state.lastActivityTime = Date.now();
          buf += decoder.decode(value);
          
          const parsed = sse.parse(buf);
          buf = parsed.rest;
          
          for (const ev of parsed.events) {
            // 更新游标（用于断点续传）
            if (typeof ev.seq === "number") {
              state.cursor = Math.max(state.cursor, ev.seq);
              dom.cursorInfo.textContent = `seq=${state.cursor}`;
            }
            
            log.append(`${ev.type} ${JSON.stringify(ev.payload ?? {})}`);
            sse.handleEvent(ev);
            
            // 如果任务已完成，退出 SSE 循环
            if (ev.type === "job.finished") {
              try { await reader.cancel(); } catch { /* ignore */ }
              log.append(`sse.completed`);
              return;  // 任务完成，直接返回
            }
          }
        }
        
        try { await reader.cancel(); } catch { /* ignore */ }
      } catch (e) {
        if (signal.aborted) return;
        log.append(`sse.error ${e.message}`);
        // 重连前等待
        await utils.sleep(CONFIG.SSE_RETRY_DELAY);
      }
    }
  },
  
  /**
   * 处理 SSE 事件
   * 
   * 核心原则：用 itemId 去重，每个消息只显示一次
   * 
   * 事件处理顺序说明：
   * 1. item.started - 消息开始（包含完整的用户消息内容）
   * 2. item.agentMessage.delta - AI 增量输出（流式）
   * 3. item.completed - 消息完成（包含完整的 AI 消息）
   * 4. job.state - 任务状态变化
   * 5. approval.required - 需要审批
   * 6. job.finished - 任务结束
   */
  handleEvent: (ev) => {
    switch (ev.type) {
      case "job.state":
        // 任务状态更新
        state.activeJobState = ev.payload?.state;
        ui.updateControls();
        break;
        
      case "approval.required":
        // 需要审批：显示审批弹窗
        log.append(`>>> 显示审批弹窗`);
        ui.showApproval(ev.payload);
        
        // 如果开启了自动审批，自动接受
        if (dom.autoApprove.checked) {
          log.append(">>> 自动审批已开启，自动接受");
          // 修复：使用 await 并处理错误
          approve("accept").catch((e) => {
            log.append(`auto_approve.error ${e.message}`);
            toast.error(`自动审批失败: ${e.message}`);
          });
        }
        break;
        
      case "job.finished":
        // 任务完成：更新状态，清理资源
        state.activeJobState = ev.payload?.state;
        state.isSending = false;
        // 修复：清理 activeJobId，避免状态混乱
        state.activeJobId = null;
        
        const finalState = ev.payload?.state;
        if (finalState === "DONE") {
          ui.setStatus("connected", "完成");
        } else {
          ui.setStatus("error", finalState || "失败");
        }
        ui.updateControls();
        break;
        
      case "item.started":
        // 消息开始事件
        // 注意：用户消息在 item.started 时包含完整内容
        sse.handleItemStarted(ev.payload);
        break;
        
      case "item.completed":
        // 消息完成事件
        // 注意：AI 消息在 item.completed 时包含完整内容
        sse.handleItemCompleted(ev.payload);
        break;
        
      case "item.agentMessage.delta":
        // AI 增量消息（流式输出）
        sse.handleAgentDelta(ev.payload);
        break;
    }
  },
  
  /**
   * 处理 item.started 事件
   * 目前只处理用户消息（userMessage）
   */
  handleItemStarted: (payload) => {
    if (payload?.item?.type !== "userMessage") return;
    
    const item = payload.item;
    const itemId = item?.id;
    
    // 去重检查：如果已经显示过，跳过
    if (itemId && state.displayedItemIds.has(itemId)) {
      log.append(`>>> 跳过已显示的用户消息 itemId=${itemId}`);
      return;
    }
    
    // 记录 itemId（防止重复显示）
    if (itemId) {
      state.displayedItemIds.add(itemId);
    }
    
    // 移除"发送中..."状态
    ui.removeSendingIndicator();
    state.isSending = false;
    
    // 解析并显示用户消息
    // 用户消息的 content 是数组格式：[{ type: "text", text: "消息内容" }]
    const content = item?.content;
    if (Array.isArray(content)) {
      const textContent = content.find(c => c.type === "text");
      if (textContent?.text) {
        ui.appendMessage("user", textContent.text);
      }
    }
  },
  
  /**
   * 处理 item.completed 事件
   * 主要处理 AI 消息（agentMessage）的完成
   */
  handleItemCompleted: (payload) => {
    if (payload?.item?.type !== "agentMessage") return;
    
    const item = payload.item;
    const itemId = item?.id;
    
    // 如果有正在构建的增量消息，完成它
    if (state.currentAssistantMsg) {
      ui.finalizeAssistantMessage();
      if (itemId) state.displayedItemIds.add(itemId);
      return;
    }
    
    // 没有增量消息（可能是重连后的历史），直接显示完整消息
    if (itemId && !state.displayedItemIds.has(itemId)) {
      const fullText = item?.text;
      if (fullText) {
        state.displayedItemIds.add(itemId);
        ui.appendMessage("assistant", fullText);
      }
    }
  },
  
  /**
   * 处理 AI 增量消息（流式输出）
   * 每次收到 delta，追加到当前正在构建的消息中
   */
  handleAgentDelta: (payload) => {
    const deltaText = typeof payload?.delta === "string" 
      ? payload.delta 
      : payload?.delta?.text;
    
    if (deltaText) {
      ui.appendAssistantDelta(deltaText);
    }
  },
  
  /** 停止 SSE 连接 */
  stop: () => {
    if (state.sseAbort) {
      state.sseAbort.abort();
      state.sseAbort = null;
    }
  },
};

// ===== 审批处理 =====
/**
 * 提交审批决定
 * 
 * @param {"accept" | "decline" | "cancel"} decision - 审批决定
 */
const approve = async (decision) => {
  if (!state.activeJobId || !state.activeApproval?.approvalId) {
    throw new Error("当前没有可审批的请求");
  }
  
  try {
    const result = await api.approveJob(
      state.activeJobId,
      state.activeApproval.approvalId,
      decision
    );
    log.append(`approval.submit ${decision}`);
    ui.hideApproval();
    toast.success(`已${decision === "accept" ? "接受" : decision === "decline" ? "拒绝" : "取消"}`);
  } catch (e) {
    log.append(`approval.error ${e.message}`);
    throw e;
  }
};

// ===== UI 界面操作 =====
const ui = {
  /** 设置状态徽章 */
  setStatus: (status, text) => {
    dom.statusBadge.className = `status-badge ${status}`;
    dom.statusBadge.querySelector(".status-text").textContent = text;
  },
  
  /** 更新控件状态（按钮禁用/启用）*/
  updateControls: () => {
    const hasThread = Boolean(state.activeThreadId);
    // 任务是否处于活跃状态（可运行或等待审批）
    const isActive = state.activeJobId && ["QUEUED", "RUNNING", "WAITING_APPROVAL"].includes(state.activeJobState || "");
    
    dom.messageInput.disabled = !hasThread || isActive;
    dom.sendBtn.disabled = !hasThread || isActive || state.isSending;
    dom.sendBtn.classList.toggle("hidden", isActive);
    dom.stopBtn.classList.toggle("hidden", !isActive);
  },
  
  /**
   * 渲染线程列表（按工作目录分组）
   */
  renderThreads: (threads) => {
    state.threads = threads;
    dom.threadsList.innerHTML = "";
    
    if (!threads.length) {
      dom.threadsList.innerHTML = '<div class="threads-empty">暂无对话</div>';
      return;
    }
    
    // 按 cwd（工作目录）分组
    const groups = {};
    threads.forEach((t) => {
      const cwd = t.cwd || "未知目录";
      if (!groups[cwd]) groups[cwd] = [];
      groups[cwd].push(t);
    });
    
    // 渲染每个分组
    Object.entries(groups).forEach(([cwd, groupThreads]) => {
      const groupDiv = document.createElement("div");
      groupDiv.className = "thread-group";
      
      // 分组标题（工作目录）
      const groupHeader = document.createElement("div");
      groupHeader.className = "thread-group-header";
      groupHeader.textContent = utils.truncate(cwd, 35);
      groupDiv.appendChild(groupHeader);
      
      // 渲染分组内的线程
      groupThreads.forEach((t) => {
        const item = document.createElement("div");
        item.className = `thread-item${t.threadId === state.activeThreadId ? " active" : ""}`;
        item.innerHTML = `
          ${SVG_ICONS.threadIcon}
          <div class="thread-info">
            <div class="thread-name">${utils.escapeHtml(utils.truncate(t.preview || "新对话", 25))}</div>
            <div class="thread-preview">${new Date(t.updatedAt * 1000).toLocaleDateString("zh-CN")}</div>
          </div>
        `;
        item.addEventListener("click", () => actions.selectThread(t.threadId));
        groupDiv.appendChild(item);
      });
      
      dom.threadsList.appendChild(groupDiv);
    });
  },
  
  /** 清空消息区域，重置状态 */
  clearMessages: () => {
    state.messages = [];
    state.currentAssistantMsg = null;
    state.displayedItemIds.clear();
    state.isSending = false;
    
    dom.messages.innerHTML = `
      <div class="welcome">
        <div class="welcome-icon">${SVG_ICONS.codexAvatar}</div>
        <h1>Codex Worker</h1>
        <p>选择或创建一个对话开始使用</p>
        <div class="welcome-hint">
          <p>你可以让 AI 帮你：</p>
          <ul>
            <li>分析代码仓库</li>
            <li>执行命令并审批</li>
            <li>创建和修改文件</li>
          </ul>
        </div>
      </div>
    `;
  },
  
  /**
   * 创建消息 DOM 元素
   * 
   * @param {"user" | "assistant"} role - 消息角色
   * @param {string} content - 消息内容
   * @returns {HTMLElement} - 创建的消息元素
   */
  createMessageElement: (role, content) => {
    const welcome = dom.messages.querySelector(".welcome");
    if (welcome) welcome.remove();
    
    // 用户发送消息时，清除当前 AI 消息引用
    if (role === "user") {
      state.currentAssistantMsg = null;
    }
    
    const msg = document.createElement("div");
    msg.className = `message ${role} message-enter`;
    
    const avatarSvg = role === "user" ? SVG_ICONS.userAvatar : SVG_ICONS.codexAvatar;
    const sender = role === "user" ? "你" : "Codex";
    
    msg.innerHTML = `
      <div class="message-avatar">${avatarSvg}</div>
      <div class="message-content">
        <div class="message-header">
          <span class="message-sender">${sender}</span>
          <span class="message-time">${utils.formatTime(new Date().toISOString())}</span>
        </div>
        <div class="message-text">${utils.escapeHtml(content)}</div>
      </div>
    `;
    
    return msg;
  },
  
  /**
   * 添加消息气泡（完整消息）
   */
  appendMessage: (role, content) => {
    const msg = ui.createMessageElement(role, content);
    dom.messages.appendChild(msg);
    state.messages.push({ role, content });
    utils.scrollToBottom();
  },
  
  /** 显示"发送中..."状态 */
  showSendingIndicator: () => {
    ui.removeSendingIndicator();
    
    const indicator = document.createElement("div");
    indicator.id = "sending-indicator";
    indicator.className = "message user message-enter sending";
    indicator.innerHTML = `
      <div class="message-avatar">${SVG_ICONS.userAvatar}</div>
      <div class="message-content">
        <div class="message-header">
          <span class="message-sender">你</span>
          <span class="message-time">发送中...</span>
        </div>
        <div class="message-text"><span class="typing-indicator"><span></span><span></span><span></span></span></div>
      </div>
    `;
    dom.messages.appendChild(indicator);
    utils.scrollToBottom();
  },
  
  /** 移除"发送中..."状态 */
  removeSendingIndicator: () => {
    const indicator = document.getElementById("sending-indicator");
    if (indicator) indicator.remove();
  },
  
  /** 显示历史加载中状态（在消息区域顶部） */
  showLoadingIndicator: () => {
    // 移除已有的
    ui.hideLoadingIndicator();
    
    // 创建加载指示器
    const loader = document.createElement("div");
    loader.id = "history-loader";
    loader.className = "history-loader";
    loader.innerHTML = `
      <div class="history-loader-spinner"></div>
      <span>加载历史消息...</span>
    `;
    
    // 插入到消息容器最前面
    const welcome = dom.messages.querySelector(".welcome");
    if (welcome) {
      welcome.before(loader);
    } else {
      dom.messages.insertBefore(loader, dom.messages.firstChild);
    }
    
    // 添加样式（如果还没有）
    if (!document.querySelector("#loader-styles")) {
      const style = document.createElement("style");
      style.id = "loader-styles";
      style.textContent = `
        .history-loader {
          display: flex;
          align-items: center;
          justify-content: center;
          gap: 10px;
          padding: 16px;
          color: var(--text-muted);
          font-size: 14px;
        }
        .history-loader-spinner {
          width: 16px;
          height: 16px;
          border: 2px solid var(--border-color);
          border-top-color: var(--accent);
          border-radius: 50%;
          animation: spin 0.8s linear infinite;
        }
        @keyframes spin {
          to { transform: rotate(360deg); }
        }
      `;
      document.head.appendChild(style);
    }
  },
  
  /** 隐藏历史加载状态 */
  hideLoadingIndicator: () => {
    const loader = document.getElementById("history-loader");
    if (loader) loader.remove();
  },
  
  /**
   * 追加 AI 增量消息（流式输出）
   * 如果当前没有 AI 消息容器，先创建一个
   */
  appendAssistantDelta: (deltaText) => {
    const welcome = dom.messages.querySelector(".welcome");
    if (welcome) welcome.remove();
    
    // 如果还没有当前 AI 消息容器，创建一个
    if (!state.currentAssistantMsg) {
      const msg = document.createElement("div");
      msg.className = "message assistant message-enter";
      msg.innerHTML = `
        <div class="message-avatar">${SVG_ICONS.codexAvatar}</div>
        <div class="message-content">
          <div class="message-header">
            <span class="message-sender">Codex</span>
            <span class="message-time">${utils.formatTime(new Date().toISOString())}</span>
          </div>
          <div class="message-text"></div>
        </div>
      `;
      dom.messages.appendChild(msg);
      // 保存消息文本容器的引用，用于后续追加
      state.currentAssistantMsg = msg.querySelector(".message-text");
    }
    
    // 追加增量文本
    if (state.currentAssistantMsg) {
      state.currentAssistantMsg.textContent += deltaText;
      utils.scrollToBottom();
    }
  },
  
  /** 完成 AI 消息（从增量模式切换到完成模式）*/
  finalizeAssistantMessage: () => {
    if (state.currentAssistantMsg) {
      const content = state.currentAssistantMsg.textContent;
      state.messages.push({ role: "assistant", content });
      state.currentAssistantMsg = null;
    }
  },
  
  // 弹窗操作
  showModal: (modal) => modal.classList.add("active"),
  hideModal: (modal) => modal.classList.remove("active"),
  
  /** 显示审批弹窗 */
  showApproval: (payload) => {
    state.activeApproval = {
      approvalId: payload.approvalId,
      kind: payload.kind,
    };
    dom.apprKind.textContent = payload.kind || "-";
    dom.apprCmd.textContent = payload.command || payload.decisionText || "-";
    dom.apprCwd.textContent = payload.cwd || "-";
    dom.apprReason.textContent = payload.reason || "-";
    ui.showModal(dom.approvalModal);
  },
  
  hideApproval: () => {
    state.activeApproval = null;
    ui.hideModal(dom.approvalModal);
  },
  
  // 侧边栏和面板切换
  toggleSidebar: () => dom.sidebar.classList.toggle("collapsed"),
  toggleMobileSidebar: () => dom.sidebar.classList.toggle("mobile-open"),
  toggleLog: () => dom.logPanel.classList.toggle("hidden"),
};

// ===== 用户操作 =====
const actions = {
  /** 初始化应用 */
  init: async () => {
    // 从本地存储加载设置
    dom.baseUrl.value = storage.get("baseUrl", utils.normalizeBaseUrl(location.origin));
    dom.token.value = storage.get("token", "");
    dom.autoApprove.checked = storage.getBool("autoApprove", false);
    
    // 检查连接状态
    const health = await api.getHealth();
    ui.setStatus(health ? "connected" : "error", health ? "已连接" : "连接失败");
    
    // 加载项目列表（用于新建对话时选择）
    try {
      const projects = await api.getProjects();
      dom.projectPath.innerHTML = projects.length
        ? projects.map((p) => `<option value="${p.projectPath}">${p.projectPath}</option>`).join("")
        : '<option value="">（未配置项目白名单）</option>';
    } catch (e) {
      log.append(`projects.error ${e.message}`);
    }
    
    // 加载线程列表
    await actions.refreshThreads();
  },
  
  /** 刷新线程列表 */
  refreshThreads: async () => {
    try {
      const threads = await api.getThreads();
      ui.renderThreads(threads);
      log.append("threads.refresh OK");
    } catch (e) {
      log.append(`threads.error ${e.message}`);
      toast.error(`加载线程失败: ${e.message}`);
    }
  },
  
  /** 选择并激活线程 */
  selectThread: async (threadId) => {
    // 先停止当前的 SSE 连接
    sse.stop();
    
    // 更新本地状态
    state.activeThreadId = threadId;
    state.activeJobId = null;
    state.activeJobState = null;
    state.cursor = -1;
    dom.cursorInfo.textContent = "";
    state.isSending = false;
    
    // 更新 UI：立即显示选中状态
    ui.renderThreads(state.threads);
    dom.activeThreadName.textContent = threadId;
    ui.updateControls();
    
    // 清空消息并显示加载状态
    ui.clearMessages();
    ui.showLoadingIndicator();
    state.isLoadingHistory = true;
    
    try {
      // 步骤 1：先从本地缓存加载（快速显示）
      await actions.loadCachedHistory(threadId);
      
      // 步骤 2：同时触发 resume（恢复服务端上下文）
      log.append(`thread.activate ${threadId}`);
      const activatedThread = await api.activateThread(threadId);
      
      // 步骤 3：再次加载缓存（resume 可能更新了数据）
      // 注意：这里只在之前没有缓存时才重新加载，避免闪烁
      if (state.messages.length === 0) {
        await actions.loadCachedHistory(threadId);
      }
      
      ui.hideLoadingIndicator();
      state.isLoadingHistory = false;
      ui.setStatus("connected", "已连接");
      
    } catch (e) {
      ui.hideLoadingIndicator();
      state.isLoadingHistory = false;
      log.append(`thread.error ${e.message}`);
      ui.setStatus("error", "加载失败");
      toast.error(`加载对话失败: ${e.message}`);
    }
    
    // 移动端关闭侧边栏
    dom.sidebar.classList.remove("mobile-open");
  },
  
  /**
   * 从本地缓存加载历史消息（快速响应）
   * 数据来源：后端 SQLite 通过 listThreadEvents 返回
   */
  loadCachedHistory: async (threadId) => {
    try {
      const events = await api.getThreadEvents(threadId);
      log.append(`thread.cache ${events.length} events`);
      
      // 如果没有缓存数据，直接返回
      if (!events || events.length === 0) {
        return;
      }
      
      for (const ev of events) {
        // 处理用户消息
        if (ev.type === "item.started" && ev.payload?.item?.type === "userMessage") {
          const item = ev.payload.item;
          const itemId = item?.id;
          
          // 去重检查
          if (itemId && state.displayedItemIds.has(itemId)) continue;
          if (itemId) state.displayedItemIds.add(itemId);
          
          const content = item?.content;
          if (Array.isArray(content)) {
            const textContent = content.find(c => c.type === "text");
            if (textContent?.text) {
              ui.appendMessage("user", textContent.text);
            }
          }
        }
        
        // 处理 AI 消息
        if (ev.type === "item.completed" && ev.payload?.item?.type === "agentMessage") {
          const item = ev.payload.item;
          const itemId = item?.id;
          
          // 去重检查
          if (itemId && state.displayedItemIds.has(itemId)) continue;
          if (itemId) state.displayedItemIds.add(itemId);
          
          const fullText = item?.text;
          if (fullText) {
            ui.appendMessage("assistant", fullText);
          }
        }
      }
    } catch (e) {
      log.append(`thread.cache.error ${e.message}`);
    }
  },
  
  /** 创建新线程 */
  createThread: async () => {
    try {
      const payload = {
        projectPath: dom.projectPath.value || undefined,
        threadName: dom.threadName.value || undefined,
        approvalPolicy: dom.approvalPolicy.value || undefined,
        sandbox: dom.sandboxMode.value || undefined,
      };
      
      const created = await api.createThread(payload);
      const tid = created?.thread?.threadId;
      
      if (tid) {
        log.append(`thread.create ${tid}`);
        ui.hideModal(dom.newThreadModal);
        dom.threadName.value = "";
        toast.success("创建对话成功");
        await actions.refreshThreads();
        await actions.selectThread(tid);
      }
    } catch (e) {
      log.append(`thread.create.error ${e.message}`);
      toast.error(`创建失败: ${e.message}`);
    }
  },
  
  /**
   * 发送消息
   * 
   * 设计原则：
   * 1. 不直接显示用户消息，由 SSE 事件驱动显示（避免状态不一致）
   * 2. 显示"发送中..."临时状态提供即时反馈
   * 3. 用 itemId 去重，避免重复显示
   */
  sendMessage: async () => {
    const text = dom.messageInput.value.trim();
    if (!text || !state.activeThreadId || state.isSending) return;
    
    // 立即清空输入框，避免用户重复提交
    dom.messageInput.value = "";
    state.isSending = true;
    
    // 显示"发送中..."状态
    ui.showSendingIndicator();
    ui.updateControls();
    
    try {
      // 构建请求
      const payload = { text };
      const ap = dom.turnApprovalPolicy.value;
      if (ap) payload.approvalPolicy = ap;
      
      // 发送请求
      const job = await api.createTurn(state.activeThreadId, payload);
      const jid = job?.jobId;
      
      if (!jid) throw new Error("未返回 jobId");
      
      // 更新状态
      state.activeJobId = jid;
      state.activeJobState = "RUNNING";
      state.cursor = -1;
      dom.cursorInfo.textContent = "seq=-1";
      ui.updateControls();
      ui.setStatus("running", "执行中");
      log.append(`turn.start jobId=${jid}`);
      
      // 启动 SSE 监听（阻塞直到任务完成）
      await sse.start(jid);
      
    } catch (e) {
      log.append(`turn.error ${e.message}`);
      ui.setStatus("error", "发送失败");
      ui.removeSendingIndicator();
      state.isSending = false;
      state.activeJobId = null;
      ui.updateControls();
      toast.error(`发送失败: ${e.message}`);
    }
  },
  
  /** 停止当前任务 */
  stopJob: async () => {
    if (!state.activeJobId) return;
    
    try {
      await api.cancelJob(state.activeJobId);
      log.append("job.cancel OK");
      sse.stop();
      state.activeJobState = "CANCELLED";
      state.activeJobId = null;
      state.isSending = false;
      ui.setStatus("connected", "已取消");
      ui.updateControls();
      toast.info("任务已取消");
    } catch (e) {
      log.append(`job.cancel.error ${e.message}`);
      toast.error(`取消失败: ${e.message}`);
    }
  },
  
  /** 保存设置 */
  saveSettings: () => {
    storage.set("baseUrl", utils.normalizeBaseUrl(dom.baseUrl.value));
    storage.set("token", dom.token.value);
    storage.setBool("autoApprove", dom.autoApprove.checked);
    ui.hideModal(dom.settingsModal);
    toast.success("设置已保存");
    actions.init();
  },
};

// ===== 事件绑定 =====
const bindEvents = () => {
  // 侧边栏操作
  dom.sidebarToggle.addEventListener("click", ui.toggleSidebar);
  dom.mobileMenuBtn.addEventListener("click", ui.toggleMobileSidebar);
  dom.newThreadBtn.addEventListener("click", () => ui.showModal(dom.newThreadModal));
  dom.refreshThreads.addEventListener("click", actions.refreshThreads);
  dom.settingsBtn.addEventListener("click", () => ui.showModal(dom.settingsModal));
  
  // 新建对话弹窗
  dom.closeNewThreadModal.addEventListener("click", () => ui.hideModal(dom.newThreadModal));
  dom.cancelNewThread.addEventListener("click", () => ui.hideModal(dom.newThreadModal));
  dom.createThread.addEventListener("click", actions.createThread);
  
  // 设置弹窗
  dom.closeSettingsModal.addEventListener("click", () => ui.hideModal(dom.settingsModal));
  dom.saveSettings.addEventListener("click", actions.saveSettings);
  
  // 审批弹窗
  dom.apprAccept.addEventListener("click", async () => {
    try {
      await approve("accept");
    } catch (e) {
      toast.error(e.message);
    }
  });
  dom.apprDecline.addEventListener("click", async () => {
    try {
      await approve("decline");
    } catch (e) {
      toast.error(e.message);
    }
  });
  dom.apprCancel.addEventListener("click", async () => {
    try {
      await approve("cancel");
    } catch (e) {
      toast.error(e.message);
    }
  });
  
  // 点击弹窗背景关闭
  document.querySelectorAll(".modal-overlay").forEach((overlay) => {
    overlay.addEventListener("click", () => {
      ui.hideModal(dom.newThreadModal);
      ui.hideModal(dom.settingsModal);
    });
  });
  
  // 日志面板操作
  dom.toggleLog.addEventListener("click", ui.toggleLog);
  dom.copyLog.addEventListener("click", () => {
    navigator.clipboard.writeText(dom.logContent.textContent).then(() => {
      toast.success("已复制到剪贴板");
    }).catch(() => {
      toast.error("复制失败");
    });
  });
  dom.clearLog.addEventListener("click", log.clear);
  dom.closeLog.addEventListener("click", () => dom.logPanel.classList.add("hidden"));
  
  // 输入框自适应高度
  dom.messageInput.addEventListener("input", () => {
    dom.messageInput.style.height = "auto";
    dom.messageInput.style.height = Math.min(dom.messageInput.scrollHeight, CONFIG.INPUT_MAX_HEIGHT) + "px";
  });
  
  // 快捷键：Enter 发送，Shift+Enter 换行
  dom.messageInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      actions.sendMessage();
    }
  });
  
  // 发送/停止按钮
  dom.sendBtn.addEventListener("click", actions.sendMessage);
  dom.stopBtn.addEventListener("click", actions.stopJob);
  
  // ESC 关闭弹窗
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      ui.hideModal(dom.newThreadModal);
      ui.hideModal(dom.settingsModal);
      ui.hideApproval();
    }
  });
  
  // 网络状态监听
  window.addEventListener("online", () => {
    toast.success("网络已恢复");
    ui.setStatus("connected", "已连接");
  });
  window.addEventListener("offline", () => {
    toast.error("网络已断开");
    ui.setStatus("error", "离线");
  });
};

// ===== 启动应用 =====
const main = async () => {
  bindEvents();
  ui.clearMessages();
  ui.updateControls();
  
  try {
    await actions.init();
    log.append("ready");
  } catch (e) {
    log.append(`init.error ${e.message}`);
    ui.setStatus("error", "初始化失败");
    toast.error(`初始化失败: ${e.message}`);
  }
};

// 启动应用，捕获致命错误
main().catch((e) => {
  console.error("Fatal error:", e);
  log.append(`FATAL ${e.message}`);
  toast.error(`致命错误: ${e.message}`);
});
