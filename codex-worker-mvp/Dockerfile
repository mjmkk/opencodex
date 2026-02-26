# ── Stage 1: 编译原生模块 ──────────────────────────────────────────────────────
FROM node:22-alpine AS builder

# better-sqlite3 和 node-pty 都需要原生编译
RUN apk add --no-cache python3 make g++

WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

# ── Stage 2: 运行镜像 ──────────────────────────────────────────────────────────
FROM node:22-alpine

# node-pty 运行时需要 python3；shell 默认使用 /bin/sh
RUN apk add --no-cache python3

WORKDIR /app

COPY --from=builder /app/node_modules ./node_modules
COPY src/ ./src/

# 持久化数据目录（SQLite 数据库）
VOLUME ["/app/data"]

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/v1/health || exit 1

CMD ["node", "src/index.js"]
