import Foundation
import Observation
import CryptoKit

/// 页面可以销毁，发件箱不能。按连接身份和线程隔离，发送意图先落盘，再进行网络操作。
@MainActor @Observable
final class ChatOutbox {
    struct Message: Codable, Identifiable, Equatable {
        enum State: Codable, Equatable { case pending, sent, unconfirmed, failed(String) }
        enum Route: String, Codable { case native, harness }
        let id: String
        let text: String
        let at: Date
        let baseline: Set<String>
        var state: State = .pending
        var route: Route = .native
        var tried = false
        var matchedID: String?
    }
    private struct Snapshot: Codable {
        var messages: [Message] = []
        var transcript: Transcript?
        var draft = ""
    }
    private static var instances: [URL: ChatOutbox] = [:]
    static func thread(_ id: String) -> ChatOutbox {
        let scope = (try? MobileSyncEngine.scope()) ?? "unconfigured"
        let name = SHA256.hash(data: Data((scope + "\n" + id).utf8)).map { String(format: "%02x", $0) }.joined()
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-outbox").appendingPathComponent(name + ".json")
        if let instance = instances[url] { return instance }
        let instance = ChatOutbox(url: url, scope: scope)
        instances[url] = instance
        return instance
    }

    private let url: URL
    private let scope: String?
    var usesCurrentConnection: Bool { scope == nil || scope == (try? MobileSyncEngine.scope()) }
    var messages: [Message]
    var cached: Transcript?
    // 打字只写很小的草稿文件，避免每个按键都重新编码整段历史。
    var draft: String = "" {
        didSet {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(draft.utf8).write(to: url.appendingPathExtension("draft"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { storageError = "草稿无法保存在本机，请检查可用空间" }
        }
    }
    var draining = false
    var storageError: String?

    init(url: URL, scope: String? = nil) {
        self.url = url
        self.scope = scope
        let snapshot = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
        messages = snapshot.messages
        cached = snapshot.transcript
        draft = (try? String(contentsOf: url.appendingPathExtension("draft"), encoding: .utf8)) ?? snapshot.draft
        for i in messages.indices where messages[i].state == .pending {
            // 进程可能在写出后退出。不自动重发；用户重试时复用原 id 并查询原通道回执。
            messages[i].state = .failed("发送被中断，请点按重试")
        }
    }

    @discardableResult func enqueue(_ text: String, rows: [Transcript.Row]) -> Bool {
        let message = Message(id: "m" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                              text: text, at: Date(), baseline: Set(rows.map(\.id)))
        messages.append(message)
        guard save() else { messages.removeLast(); return false }
        return true
    }

    /// 一条服务端用户记录只能认领一条本地消息。旧记录、未尝试投递的消息都不能收起新气泡。
    func reconcile(_ rows: [Transcript.Row]) {
        var claimed = Set(messages.compactMap(\.matchedID))
        for i in messages.indices where messages[i].matchedID == nil && messages[i].tried {
            let m = messages[i]
            if let row = rows.first(where: {
                $0.kind == .user(m.text) && !m.baseline.contains($0.id) && !claimed.contains($0.id)
                && ($0.at.map { $0 >= m.at.addingTimeInterval(-2) } ?? false)
            }) {
                messages[i].matchedID = row.id
                messages[i].state = .sent
                claimed.insert(row.id)
            }
        }
        save()
    }

    func remember(_ transcript: Transcript) {
        cached = Transcript(rows: Array(transcript.rows.suffix(500)), model: transcript.model,
                            isPartial: transcript.isPartial, hasMore: transcript.hasMore || transcript.rows.count > 500)
        reconcile(transcript.rows)
    }

    @discardableResult func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Snapshot(messages: messages, transcript: cached, draft: draft))
                .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            storageError = nil
            return true
        } catch {
            storageError = "消息无法保存在本机，请检查可用空间后重试"
            return false
        }
    }
}
