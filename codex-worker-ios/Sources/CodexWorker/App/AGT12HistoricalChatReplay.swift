#if AGT12_UI_REPLAY
import ComposableArchitecture
import CryptoKit
import ExyteChat
import Foundation
import MarkdownUI
import SwiftUI

/// Engineering-only rendering of an existing, immutable historical response.
/// The normal Release build excludes this view and never bundles the response.
/// This reducer performs no transport, persistence, native response or AI call.
struct AGT12HistoricalChatReplay: View {
    private let store: StoreOf<ChatFeature>?
    private let summary: String
    private let failure: String?
    private let selectionSummary: String?

    init(path: String) {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == "393407606be0a51e8813c8bfc95e7cf2efb2bf606f3af30528d195ebbc7b6b4d" else { throw CodexError.invalidState }
            let body = try JSONDecoder().decode(MirrorBody.self, from: data)
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
                    text: $0.text, status: nil, createdAt: $0.sentAt ?? .distantPast)
            }
            if let raw = ProcessInfo.processInfo.environment["AGT12_CHAT_REPLAY_MESSAGE_INDEX"] {
                guard let index = Int(raw), state.messages.indices.contains(index) else { throw CodexError.invalidState }
                state.messages = [state.messages[index]]
                self.selectionSummary = "本页仅看原文第 \(body.page.offset + index + 1) 条（片段内 \(index + 1)/\(body.messages.count)）"
            } else { self.selectionSummary = nil }
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
            self.selectionSummary = nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary).font(.footnote.weight(.semibold))
                Text("离线阅读回放 · 不执行历史指令或操作").font(.caption).foregroundStyle(.secondary)
                if let selectionSummary { Text(selectionSummary).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground))
            if let store {
                CodexChatView(store: store, showsComposer: ProcessInfo.processInfo.environment["AGT12_CHAT_REPLAY_SHOWS_COMPOSER"] == "1")
                    .markdownImageProvider(HistoricalReplayImages())
                    .markdownInlineImageProvider(HistoricalReplayImages())
            } else {
                CodexEmptyState(title: "无法读取历史原件", detail: failure ?? "读取失败")
            }
        }
        .tint(.primary)
    }
}

private struct HistoricalReplayImages: ImageProvider, InlineImageProvider {
    func makeImage(url: URL?) -> some View {
        Label("历史图片未载入", systemImage: "photo").font(.footnote).foregroundStyle(.secondary)
    }
    func image(with url: URL, label: String) async throws -> Image {
        // A rendering replay never fetches an external image as a side effect.
        throw CodexError.notConfigured
    }
}
#endif
