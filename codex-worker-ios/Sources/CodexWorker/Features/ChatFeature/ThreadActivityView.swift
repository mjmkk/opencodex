import Foundation
import SwiftUI

public struct ThreadActivityItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var event: EventEnvelope

    static func collect(_ events: [EventEnvelope]) -> [Self] {
        var items: [Self] = []
        for event in events {
            let item = event.payload?["item"]?.objectValue ?? [:]
            let kind = item["type"]?.stringValue ?? event.type
            guard event.detailCursor != nil || event.type == "error" ||
                    (["item.started", "item.completed"].contains(event.type) &&
                     !["agentMessage", "userMessage"].contains(kind)) else { continue }
            let id = event.jobId + ":" + (item["id"]?.stringValue ?? "\(event.threadCursor ?? event.seq):\(event.type)")
            let labels = ["commandExecution": "命令执行", "fileChange": "文件修改", "mcpToolCall": "工具结果", "webSearch": "搜索", "reasoning": "工作进展", "error": "错误"]
            let result = Self(id: id, title: labels[kind] ?? "执行记录", event: event)
            if let index = items.firstIndex(where: { $0.id == id }) { items[index] = result }
            else { items.append(result) }
        }
        return items
    }

    var preview: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(event.payload).flatMapText) ?? "暂无详细内容"
    }
}

private extension Data { var flatMapText: String { String(decoding: self, as: UTF8.self) } }

struct ThreadActivityDetailView: View {
    let item: ThreadActivityItem
    let threadId: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var offset = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(text.isEmpty ? item.preview : text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if let error { Text(error).foregroundStyle(.secondary) }
                    if item.event.detailCursor != nil && hasMore {
                        Button(loading ? "正在加载…" : (text.isEmpty ? "加载完整内容" : "继续加载")) {
                            Task { await loadNext() }
                        }.disabled(loading)
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(item.title)
            .toolbar { Button("关闭") { dismiss() } }
        }
    }

    private struct DetailPage: Decodable { let text: String; let nextOffset: Int; let hasMore: Bool }
    @MainActor private func loadNext() async {
        guard let cursor = item.event.detailCursor, let generation = item.event.detailGeneration,
              let configuration = WorkerConfiguration.load(), !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            var url = URLComponents(string: configuration.baseURL + "/v1/threads/\(threadId)/events/\(cursor)/detail")
            url?.queryItems = [.init(name: "generation", value: generation), .init(name: "offset", value: String(offset))]
            guard let target = url?.url else { throw CodexError.invalidState }
            var request = URLRequest(url: target); request.timeoutInterval = 15
            if let token = configuration.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard WorkerConfiguration.load() == configuration,
                  (response as? HTTPURLResponse)?.statusCode == 200 else { throw CodexError.invalidState }
            let page = try JSONDecoder().decode(DetailPage.self, from: data)
            text += page.text; offset = page.nextOffset; hasMore = page.hasMore
        } catch { self.error = "完整内容暂时无法加载，已保存的摘要仍可阅读。" }
    }
}
