#if AGT12_UI_REPLAY
import ComposableArchitecture
import ExyteChat
import Foundation
import SwiftUI

/// Engineering-only rendering of an existing, immutable historical response.
/// The normal Release build excludes this view and never bundles the response.
/// This reducer performs no transport, persistence, native response or AI call.
struct AGT12HistoricalChatReplay: View {
    private let store: StoreOf<ChatFeature>?
    private let summary: String
    private let failure: String?

    init(path: String) {
        do {
            let body = try JSONDecoder().decode(MirrorBody.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard body.ok, body.source == "local_mirror", body.page.scope == "local_only",
                  body.thread.namespace == body.namespace else { throw CodexError.invalidState }
            // This time describes the local read, never the messages' send times.
            let readAt = Date(timeIntervalSince1970: 1792836747.609732)
            let history = MirrorCachedBody(body: body, downloadedAt: readAt).history
            var state = ChatFeature.State()
            state.activeThread = body.thread.thread(in: body.namespace)
            state.history = history
            state.messages = history.messages.map {
                ChatMessageAdapter.makeMessage(id: $0.id,
                    sender: $0.role == "user" ? .user : ($0.role == "assistant" ? .assistant : .system),
                    text: $0.text, createdAt: $0.sentAt ?? .distantPast)
            }
            // No source-sync timestamp is manufactured from the replay read time.
            self.store = Store(initialState: state) {
                Reduce<ChatFeature.State, ChatFeature.Action> { _, _ in .none }
            }
            self.summary = "真实历史片段 · \(body.messages.count) / \(body.page.local_total) · \(body.isPartial ? "partial" : "来源范围")"
            self.failure = nil
        } catch {
            self.store = nil
            self.summary = "历史回放未载入"
            self.failure = error.localizedDescription
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary).font(.footnote.weight(.semibold))
                Text("离线阅读回放 · 不执行历史指令或操作").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground))
            if let store {
                CodexChatView(store: store, showsComposer: false)
            } else {
                CodexEmptyState(title: "无法读取历史原件", detail: failure ?? "读取失败")
            }
        }
        .tint(.primary)
    }
}
#endif
