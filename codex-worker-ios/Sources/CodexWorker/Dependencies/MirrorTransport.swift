import Foundation

/// Read-only facts from the current AGT-28 namespace. These are not job events.
public struct MirrorThread: Codable, Equatable, Sendable {
    public var thread_id: String
    public var namespace: String?
    public var kind: String?
    public var host_id: String?
    public var metadata: [String: JSONValue]?
    public var last_seen_at: String?
    public var last_checked_at: String?
    public var last_synced_at: String?
    public var content_coverage: JSONValue?
    public var attachment_coverage: JSONValue?
    public var upstream_state: JSONValue?
    public var refresh_requested: Bool?

    func thread(in namespace: String) -> Thread {
        var thread = Thread(threadId: thread_id, preview: nil,
            cwd: metadata?["cwd"]?.stringValue,
            createdAt: timestamp(metadata?["createdAt"]),
            updatedAt: timestamp(metadata?["updatedAt"]), modelProvider: nil)
        thread.name = metadata?["title"]?.stringValue ?? metadata?["name"]?.stringValue
        thread.nativeManaged = true
        thread.origin = .init(namespace: namespace, hostID: host_id)
        // Catalog status is retained as a source fact. It cannot authorize a write
        // or prove that a request was resolved or a turn resumed.
        return thread
    }

    private func timestamp(_ value: JSONValue?) -> String? {
        if let text = value?.stringValue { return text }
        guard let epoch = value?.doubleValue, epoch.isFinite else { return nil }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch))
    }

    var coverageLabel: String {
        switch content_coverage?.stringValue {
        case "complete": return "已缓存来源当前提供的历史"
        case "partial": return "部分历史已缓存"
        case "none", "metadata_only": return "当前仅有任务目录"
        default: return "历史覆盖范围待核对"
        }
    }
}

public struct MirrorIndex: Codable, Equatable, Sendable {
    public var ok: Bool
    public var namespace: String
    public var source: String
    public var threads: [MirrorThread]
    public var limit: Int?
    public var possibly_truncated: Bool?
    public var refresh_requested: Bool?
}

public struct MirrorMessage: Codable, Equatable, Sendable {
    public var native_id: String
    public var role: String?
    public var text_content: String?
    public var last_seen_at: String?
}

public struct MirrorItem: Codable, Equatable, Sendable {
    public var native_id: String
    public var type: String?
    public var last_seen_at: String?
}

public struct MirrorAttachment: Codable, Equatable, Sendable {
    public var native_id: String
    public var mime: String?
    public var state: String?
    public var filename: String?
}

public struct MirrorPage: Codable, Equatable, Sendable {
    public var offset: Int
    public var limit: Int
    public var local_total: Int
    public var snapshot: String
    public var next_offset: Int?
    public var scope: String
}

public struct MirrorBody: Codable, Equatable, Sendable {
    public var ok: Bool
    public var namespace: String
    public var source: String
    public var thread: MirrorThread
    public var messages: [MirrorMessage]
    public var items: [MirrorItem]
    public var attachments: [MirrorAttachment]
    public var page: MirrorPage
    public var refresh_requested: Bool?

    public var isPartial: Bool { page.next_offset != nil || thread.content_coverage?.stringValue != "complete" }

    mutating func append(_ next: MirrorBody) throws {
        guard namespace == next.namespace, thread.thread_id == next.thread.thread_id,
              page.snapshot == next.page.snapshot, page.next_offset == next.page.offset,
              next.page.next_offset == nil || next.page.next_offset! > next.page.offset else {
            throw CodexError.cursorExpired
        }
        // The service's array order is authoritative, including its fallback order.
        var seen = Set(messages.map(\.native_id))
        messages += next.messages.filter { seen.insert($0.native_id).inserted }
        var itemIDs = Set(items.map(\.native_id))
        items += next.items.filter { itemIDs.insert($0.native_id).inserted }
        var attachmentIDs = Set(attachments.map(\.native_id))
        attachments += next.attachments.filter { attachmentIDs.insert($0.native_id).inserted }
        page.next_offset = next.page.next_offset; page.local_total = next.page.local_total
        refresh_requested = refresh_requested == true || next.refresh_requested == true
    }
}

struct MirrorCachedBody: Codable, Equatable, Sendable {
    var body: MirrorBody
    var downloadedAt: Date
}

extension MirrorCachedBody {
    var history: ThreadHistory {
        ThreadHistory(threadIdentity: body.thread.thread(in: body.namespace).id,
            messages: body.messages.map { .init(id: $0.native_id, role: $0.role, text: $0.text_content ?? "（此条记录未提供文本）", sentAt: nil) },
            records: body.items.map { .init(id: $0.native_id, title: $0.type ?? "原始记录", observedAt: $0.last_seen_at) },
            attachments: body.attachments.map { .init(id: $0.native_id, filename: $0.filename ?? $0.native_id, availability: $0.state ?? "状态未知") },
            downloadedAt: downloadedAt, isPartial: body.isPartial, hasMore: body.page.next_offset != nil,
            availableMessageCount: body.page.local_total, refreshRequested: body.refresh_requested == true)
    }
}
