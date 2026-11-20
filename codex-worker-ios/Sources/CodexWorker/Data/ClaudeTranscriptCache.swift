import Foundation

/// Claude 会话正文的本地缓存：打开时先显示上次的内容，再去服务端拉最新的。放在 Caches 目录，系统清了也只是第一次慢一点
enum ClaudeTranscriptCache {
    private static func url(_ id: String) -> URL? {
        guard let scope = try? MobileSyncEngine.scope() else { return nil }
        let safe = id.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("claude-transcripts", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true).appendingPathComponent(safe + ".json")
    }
    static func load(_ id: String) async -> JSONValue? {
        guard let url = url(id) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        }.value
    }
    static func save(_ id: String, _ json: JSONValue) async {
        guard let url = url(id) else { return }
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(json).write(to: url, options: .atomic)
        }.value
    }
}
