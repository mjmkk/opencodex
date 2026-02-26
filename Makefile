.PHONY: help test test-backend test-ios lint format build dev setup clean

# 默认目标：显示帮助
help: ## 显示所有可用命令
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ── 测试 ───────────────────────────────────────────────────────────────────────

test: test-backend test-ios ## 运行全部测试（后端 + iOS）

test-backend: ## 运行 Node.js 后端测试
	@echo "▶ codex-worker-mvp"
	cd codex-worker-mvp && npm ci --silent && npm test
	@echo "▶ codex-sessions-tool"
	cd codex-sessions-tool && npm ci --silent && npm test

test-ios: ## 运行 Swift Package 单元测试
	cd codex-worker-ios && xcodebuild test \
	  -scheme CodexWorker \
	  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
	  -skipMacroValidation \
	  | xcbeautify || xcodebuild test \
	    -scheme CodexWorker \
	    -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
	    -skipMacroValidation

# ── 代码风格 ──────────────────────────────────────────────────────────────────

lint: ## 运行 SwiftFormat lint + SwiftLint 检查
	swiftformat --lint . --config .swiftformat
	swiftlint lint --config .swiftlint.yml

format: ## 自动修复 Swift 格式问题
	swiftformat . --config .swiftformat

# ── 构建 ───────────────────────────────────────────────────────────────────────

build: ## 构建 iOS App（Simulator）
	cd CodexWorkerApp/CodexWorkerApp && xcodebuild \
	  -project CodexWorkerApp.xcodeproj \
	  -scheme CodexWorkerApp \
	  -destination 'generic/platform=iOS Simulator' \
	  -skipMacroValidation \
	  build

# ── 开发 ───────────────────────────────────────────────────────────────────────

dev: ## 启动后端（开发模式）
	@echo "⚙️  启动 codex-worker-mvp..."
	@echo "⚠️  请确保 codex-worker-mvp/worker.config.json 已配置"
	cd codex-worker-mvp && node src/index.js

setup: ## 安装所有依赖
	cd codex-worker-mvp && npm install
	cd codex-sessions-tool && npm install
	@echo "✅ Node.js 依赖安装完成"
	@echo "提示：iOS 依赖由 Xcode 在首次构建时自动解析"

# ── Docker ────────────────────────────────────────────────────────────────────

docker-up: ## 用 Docker Compose 启动后端
	@if [ ! -f codex-worker-mvp/worker.config.json ]; then \
	  echo "❌ 缺少 codex-worker-mvp/worker.config.json"; \
	  echo "   请先执行：cp codex-worker-mvp/worker.config.example.json codex-worker-mvp/worker.config.json"; \
	  exit 1; \
	fi
	docker compose up --build -d

docker-down: ## 停止 Docker Compose 服务
	docker compose down

docker-logs: ## 查看后端容器日志
	docker compose logs -f worker

# ── 清理 ───────────────────────────────────────────────────────────────────────

clean: ## 清理构建产物
	rm -rf codex-worker-ios/.build
	rm -rf codex-worker-mvp/coverage
	rm -rf codex-sessions-tool/coverage
	@echo "✅ 清理完成"
